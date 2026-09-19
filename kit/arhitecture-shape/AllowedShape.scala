package io.github.mercurievv.arhitecture.scalafix

import metaconfig.{Conf, ConfDecoder, Configured}
import scalafix.v1.*

import scala.meta.*

/** A module's allowed-types allowlist and disallowed-constructs denylist, configured per module via
  * `AllowedShapeModule` — there's no project-wide default, since different layers permit different things.
  *
  * Type check (when `allowedTypes` is non-empty): every referenced type outside an `import`, plus any
  * object-valued `Term.Name`/`Importee` (e.g. `Kleisli.catsDataArrowChoiceForKleisli(...)` names the `Kleisli`
  * object without ever writing it as a `Type.Name`, which a type-only check would miss), must resolve to a
  * symbol matching an entry in `allowedTypes` — used as both exact names and package prefixes.
  *
  * Construct check is a denylist (`disallowedConstructs`, e.g. `"TermIf"`, `"TermMatch"`) rather than an
  * allowlist, since most AST shapes are unavoidable scaffolding; a module needing one removes it from its own
  * list instead of a global exception growing.
  */
final case class AllowedShapeConfig(
    allowedTypes: List[String] = Nil,
    disallowedConstructs: List[String] = Nil,
)

object AllowedShapeConfig {
  val default: AllowedShapeConfig = AllowedShapeConfig()

  given ConfDecoder[AllowedShapeConfig] with
    def read(conf: Conf): Configured[AllowedShapeConfig] = conf match
      case obj: Conf.Obj =>
        obj.getOrElse[List[String]]("allowedTypes")(default.allowedTypes).andThen { types =>
          obj
            .getOrElse[List[String]]("disallowedConstructs")(default.disallowedConstructs)
            .map(constructs => AllowedShapeConfig(types, constructs))
        }
      case _ => Configured.error("AllowedShape config must be an object, e.g. `AllowedShape.allowedTypes = [...]`")
}

class AllowedShape(config: AllowedShapeConfig) extends SemanticRule("AllowedShape") {
  def this() = this(AllowedShapeConfig.default)

  override def withConfiguration(configuration: Configuration): Configured[Rule] =
    configuration.conf
      .getOrElse[AllowedShapeConfig]("AllowedShape")(AllowedShapeConfig.default)
      .map(new AllowedShape(_))

  private val allowedTypeMatcher = SymbolMatcher.exact(config.allowedTypes*)
  private val typeCheckEnabled   = config.allowedTypes.nonEmpty

  /** The node's own kind (`"TermIf"`, `"DefnObject"`, ...). Every scalameta node class is generated as
    * `<Kind>Impl`, so stripping the suffix names every kind without a per-construct match.
    */
  private def constructNameOf(t: Tree): String = t.getClass.getSimpleName.stripSuffix("Impl")

  private def isDisallowedConstruct(name: String): Boolean = config.disallowedConstructs.contains(name)

  private val whatToDo = "Think to extract this code to another, less restrictive module. Or abstract over type."

  private def diag(name: String, pos: Position): Patch =
    Patch.lint(Diagnostic("disallowedConstruct", s"`$name` is in this module's disallowed-constructs list. $whatToDo", pos))

  private def insideImport(tree: Tree): Boolean =
    tree.parent.exists {
      case _: Importer | _: Importee => true
      case parent                    => insideImport(parent)
    }

  /** Whether `name` is a type/trait/class declaring its own name (e.g. `trait Foo`'s `Foo`, or `type Event =
    * Evt[V]`'s `Event`) rather than referencing another type — such definitions state this module's own shape
    * and aren't policed; every real reference (`Evt[V]` itself) is still checked.
    */
  private def isTypeDefinitionName(name: Type.Name): Boolean =
    name.parent.exists {
      case d: Defn.Trait => d.name eq name
      case d: Defn.Class => d.name eq name
      case d: Defn.Enum  => d.name eq name
      case d: Defn.Type  => d.name eq name
      case d: Decl.Type  => d.name eq name
      case _             => false
    }

  /** A type-parameter binder (`[F[_]]`, and its later references within scope) or a compiler-synthesized
    * local (existential, placeholder `_`) — not a reference to check. By scalameta convention these symbols
    * end in `]` or start with `local`; a genuine named type's symbol ends in `#`.
    */
  private def isBinderOrLocal(symbol: Symbol): Boolean =
    symbol.value.startsWith("local") || symbol.value.endsWith("]")

  private def isAllowedType(symbol: Symbol): Boolean =
    isBinderOrLocal(symbol) ||
      config.allowedTypes.exists(symbol.value.startsWith)

  /** Whether `symbol` names an object/module — the term-level counterpart of "is a type". For this project's
    * own code, `SymbolInformation.isObject` answers directly. For a dependency-jar symbol (semanticdb only
    * describes what this module compiles, not its classpath), `doc.info` returns `None`, so fall back to the
    * symbol string convention: term symbols end in `.`, methods in `().`/`(+n).`, so a `.`-terminated,
    * capitalized name is treated as an object.
    */
  private def isObjectReference(symbol: Symbol)(implicit doc: SemanticDocument): Boolean =
    doc.info(symbol) match
      case Some(info) => info.isObject
      case None       => symbol.value.endsWith(".") && symbol.displayName.headOption.exists(_.isUpper)

  /** Whether `symbol` is a type (`#`-suffixed) or an object — the two kinds an `import` is worth checking
    * against the allowlist. A method or `val` import (`toFunctorOps`) is just syntax, not policed.
    */
  private def isTypeOrObject(symbol: Symbol)(implicit doc: SemanticDocument): Boolean =
    symbol.value.endsWith("#") || isObjectReference(symbol)

  override def fix(implicit doc: SemanticDocument): Patch = {
    val constructs = doc.tree.collect {
      case t if isDisallowedConstruct(constructNameOf(t)) => diag(constructNameOf(t), t.pos)
    }.asPatch

    val types =
      if !typeCheckEnabled then Patch.empty
      else
        doc.tree.collect {
          case t: Type.Name
              if !insideImport(t)
                && !isTypeDefinitionName(t)
                && t.symbol.value.nonEmpty
                && !isAllowedType(t.symbol) =>
            Patch.lint(
              Diagnostic(
                "disallowedType",
                s"type `${t.symbol.displayName}` (symbol `${t.symbol.value}`) not in this module's allowed-types list. $whatToDo",
                t.pos,
              )
            )
          case t: Term.Name
              if !insideImport(t)
                && t.symbol.value.nonEmpty
                && isObjectReference(t.symbol)
                && !isAllowedType(t.symbol) =>
            Patch.lint(
              Diagnostic(
                "disallowedType",
                s"type `${t.symbol.displayName}` (symbol `${t.symbol.value}`, referenced as a term) not in this module's allowed-types list. $whatToDo",
                t.pos,
              )
            )
          // An import names a type as plainly as a usage — flag it here so a disallowed type fails at the line
          // stating intent to use it, even one reached only via an unwritten given.
          case i @ Importee.Name(n)
              if n.symbol.value.nonEmpty
                && isTypeOrObject(n.symbol)
                && !isAllowedType(n.symbol) =>
            Patch.lint(
              Diagnostic(
                "disallowedType",
                s"import of `${n.symbol.displayName}` (symbol `${n.symbol.value}`) not in this module's allowed-types list. $whatToDo",
                i.pos,
              )
            )
          case i @ Importee.Rename(n, _)
              if n.symbol.value.nonEmpty
                && isTypeOrObject(n.symbol)
                && !isAllowedType(n.symbol) =>
            Patch.lint(
              Diagnostic(
                "disallowedType",
                s"import of `${n.symbol.displayName}` (symbol `${n.symbol.value}`) not in this module's allowed-types list. $whatToDo",
                i.pos,
              )
            )
        }.asPatch

    constructs + types
  }
}
