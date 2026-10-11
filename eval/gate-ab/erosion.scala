//> using scala 3.8.4
//> using dep org.scalameta::scalameta:4.17.3
// erosion.scala <file>...: per-method cyclomatic complexity and SLOC as JSON (spec 2026-10-11 chained feature work §3).
import scala.meta.*

given Dialect = dialects.Scala3

def own(t: Tree): Int = t match
  case _: Term.If | _: Case | _: Term.While | _: Enumerator.Guard     => 1
  case a: Term.ApplyInfix if a.op.value == "&&" || a.op.value == "||" => 1
  case _                                                              => 0

// A nested def is its own method: its branches are not the enclosing method's.
def branches(t: Tree): Int = t match
  case _: Defn.Def => 0
  case _           => own(t) + t.children.map(branches).sum

def sloc(lines: Array[String], d: Defn.Def): Int =
  (d.pos.startLine to d.pos.endLine).count { i =>
    val l = lines(i).trim
    l.nonEmpty && !l.startsWith("//") && !l.startsWith("/*") && !l.startsWith(
      "*"
    )
  }

def esc(s: String): String = s.flatMap {
  case '"'  => "\\\""
  case '\\' => "\\\\"
  case c    => c.toString
}

@main def erosion(files: String*): Unit =
  val rows = files.flatMap { f =>
    val text = String(
      java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(f)),
      "UTF-8"
    )
    val lines = text.split("\n", -1)
    Input
      .VirtualFile(f, text)
      .parse[Source]
      .get
      .collect { case d: Defn.Def => d }
      .map { d =>
        s"""{"file":"${esc(f)}","name":"${esc(
            d.name.value
          )}","line":${d.pos.startLine + 1},"cc":${1 + branches(
            d.body
          )},"sloc":${sloc(lines, d)}}"""
      }
  }
  println(rows.mkString("{\"methods\":[", ",", "]}"))
