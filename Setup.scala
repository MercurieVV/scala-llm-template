//> using scala 3.8.4
//> using dep io.github.mercurievv::arrowstep:0.1.1
//> using dep org.typelevel::cats-core:2.13.0
//> using dep org.typelevel::cats-effect:3.7.0
//> using dep com.lihaoyi::os-lib:0.11.8
//> using dep com.lihaoyi::ujson:4.4.3

import arrowstep.core.{
  AskInput,
  Flow,
  ProgramSays,
  Question,
  QuestionKind,
  Validator,
  ValidAnswers
}
import arrowstep.runtime.{AgentArgs, AgentMain, AnswerLog, ReplayAsk}
import cats.effect.{ExitCode, IO, IOApp}
import cats.syntax.all.*
import scala.io.StdIn.readLine

case class Feature(
    id: String,
    group: String,
    name: String,
    prompt: String,
    defaultValue: String
)

object Setup extends IOApp:
  private val OfflineScalaVersion = "3.3.3"

  private final case class SetupContext(
      targetDir: os.Path,
      answers: Map[String, String],
      finalScalaVersion: String
  )

  private final case class StepResult(
      id: String,
      status: String,
      message: String,
      files: List[String] = Nil
  ):
    def json: ujson.Value =
      ujson.Obj(
        "id" -> id,
        "status" -> status,
        "message" -> message,
        "files" -> ujson.Arr(files.map(ujson.Str.apply)*)
      )

  private trait SetupStep:
    def id: String
    def run(ctx: SetupContext): StepResult

  /** One fenced code block of a recipe: the language it is tagged with, and its body without the fences. */
  private final case class CodeBlock(lang: String, body: String)

  def getFeaturesList(defaultScalaVersion: String): List[Feature] = List(
    // 1. Build & Compilation
    Feature(
      "scala-version",
      "Core",
      "Scala Version",
      "Enter Scala version",
      defaultScalaVersion
    ),
    Feature(
      "cross-version",
      "Core",
      "Cross Version Compilation",
      "Enable cross version compilation? (yes/no)",
      "no"
    ),
    Feature(
      "build-tool",
      "Core",
      "Build Tool",
      "Primary build tool (mill/sbt/scala-cli)",
      "scala-cli"
    ),
    Feature(
      "scripts",
      "Core",
      "Scripting Tool",
      "Scripting wrapper (scala-cli/none)",
      "none"
    ),
    Feature(
      "github-flow",
      "Core",
      "GitHub Flow Integration",
      "Enable GitHub Flow (CI Workflow)? (yes/no)",
      "yes"
    ),
    Feature(
      "sdkmanrc",
      "Core",
      "SDKMAN! Configuration",
      "Enable SDKMAN! configuration (.sdkmanrc)? (yes/no)",
      "yes"
    ),

    // 2. Ecosystem & Frameworks
    Feature(
      "ecosystem",
      "Ecosystem",
      "Primary Ecosystem",
      "Ecosystem (typelevel, zio, none)",
      "none"
    ),
    Feature(
      "web-server",
      "Ecosystem",
      "Web Server",
      "Enable Web Server? (yes/no)",
      "no"
    ),
    Feature(
      "web-client",
      "Ecosystem",
      "Web Client",
      "Enable Web Client? (yes/no)",
      "no"
    ),
    Feature(
      "db-access",
      "Ecosystem",
      "Database Access",
      "Enable Database Access? (yes/no)",
      "no"
    ),
    Feature(
      "serverless-run",
      "Ecosystem",
      "Serverless Deployment",
      "Enable Serverless run? (yes/no)",
      "no"
    ),
    Feature(
      "api-docs",
      "Ecosystem",
      "Tapir API Documentation",
      "Enable Tapir (declarative endpoints)? (yes/no)",
      "no"
    ),
    Feature(
      "logging",
      "Ecosystem",
      "Logging Facade (Logback + Log4cats/ZIO Logging)",
      "Enable Logging Facade (Logback)? (yes/no)",
      "yes"
    ),

    // 3. Verification & Quality Assurance
    Feature(
      "test-tools",
      "Quality Assurance",
      "Testing Framework",
      "Test tools (munit+shapeless, zio-test, none)",
      "munit+shapeless"
    ),
    Feature(
      "stainless",
      "Quality Assurance",
      "Stainless Verification",
      "Enable Stainless formal verification? (yes/no)",
      "no"
    ),
    Feature(
      "stryker",
      "Quality Assurance",
      "Stryker Mutation Testing",
      "Enable Stryker mutation testing? (yes/no)",
      "yes"
    ),
    Feature(
      "performance-testing",
      "Quality Assurance",
      "JMH Performance Testing",
      "Enable JMH performance testing? (yes/no)",
      "no"
    ),
    Feature(
      "scoverage",
      "Quality Assurance",
      "Scoverage Code Coverage",
      "Enable Scoverage code coverage? (yes/no)",
      "yes"
    ),
    Feature(
      "kit",
      "Quality Assurance",
      "Arhitecture-shape rule, skills and lint wiring",
      "Vendor the AllowedShape rule, its build wiring and the five skills? (yes/no)",
      "no"
    ),

    // 4. Data Utilities
    Feature(
      "optics",
      "Data Utilities",
      "Monocle Optics",
      "Enable Monocle (lenses/optics for immutable structures)? (yes/no)",
      "no"
    ),
    Feature(
      "dto-mapping",
      "Data Utilities",
      "Chimney DTO Mapping",
      "Enable Chimney (type-safe data transformation)? (yes/no)",
      "no"
    ),
    Feature(
      "config-loader",
      "Data Utilities",
      "Configuration Loader (PureConfig/Ciris)",
      "Enable PureConfig configuration loading? (yes/no)",
      "no"
    ),

    // 5. Developer Tooling
    Feature(
      "mcp-tools",
      "Developer Tooling",
      "ScalaSemantic MCP Integration",
      "Enable ScalaSemantic MCP integration (generate rules & configs)? (yes/no)",
      "yes"
    ),
    Feature(
      "mdoc",
      "Developer Tooling",
      "Mdoc Compiler",
      "Enable Mdoc (type-checked documentation)? (yes/no)",
      "yes"
    ),
    Feature(
      "git-hooks",
      "Developer Tooling",
      "Git Hooks Integration",
      "Enable Git pre-commit and pre-push hooks? (yes/no)",
      "yes"
    ),
    Feature(
      "version-bump",
      "Developer Tooling",
      "Version Bumping Utility",
      "Enable semantic version bumping script? (yes/no)",
      "yes"
    ),
    Feature(
      "docker",
      "Developer Tooling",
      "Docker Configuration",
      "Enable Docker configuration (Dockerfile)? (yes/no)",
      "yes"
    )
  )

  def run(args: List[String]): IO[ExitCode] =
    AgentArgs.parseKnown(args) match
      case Left(message) =>
        IO(Console.err.println(message)).as(ExitCode.Error)
      case Right(parsed) =>
        runParsed(parsed.args, parsed.rest)

  private def runParsed(
      runtimeArgs: AgentArgs,
      consumerArgs: List[String]
  ): IO[ExitCode] =
    for
      targetDir <- IO.blocking(resolveTargetDir(consumerArgs))
      _ <- prepareAnswerLog(targetDir, runtimeArgs)
      featuresToPrompt <- prepareFeatures(targetDir)
      program = setupProgram(runtimeArgs, targetDir, featuresToPrompt)
      exitCode <-
        if runtimeArgs.agent then AgentMain.run[IO](program).flatMap(emit)
        else program.void.as(ExitCode.Success)
    yield exitCode

  private def setupProgram(
      runtimeArgs: AgentArgs,
      targetDir: os.Path,
      featuresToPrompt: List[Feature]
  ): IO[ProgramSays[ujson.Value]] =
    for
      answers <-
        if runtimeArgs.agent then setupFlow(targetDir).run(featuresToPrompt)
        else IO.blocking(promptFeaturesGrouped(featuresToPrompt))
      result <- writeProject(targetDir, answers)
    yield ProgramSays.Done(result)

  private def resolveTargetDir(args: List[String]): os.Path =
    args.headOption match
      case Some(".") | None => os.pwd
      case Some(path)       =>
        val d = os.Path(path, os.pwd)
        if !os.exists(d) then os.makeDir.all(d)
        d

  private def prepareFeatures(targetDir: os.Path): IO[List[Feature]] =
    for
      _ <- IO(
        Console.err.println(
          "=== Scala Project Setup & Update (Mill/SBT/Scala-CLI + Global Rules) ==="
        )
      )
      isExisting <- IO.blocking(projectExists(targetDir))
      _ <-
        if isExisting then
          IO(
            Console.err.println(
              s"Found existing project in $targetDir. Switching to update mode."
            )
          )
        else
          IO(Console.err.println(s"Initializing new project in $targetDir..."))
      _ <- IO(
        Console.err.println(
          "Resolving latest stable Scala 3 version from Maven Central..."
        )
      )
      defaultScalaVersion <- IO
        .blocking(
          fetchLatestStableVersion("org.scala-lang", "scala3-compiler_3")
        )
        .flatMap {
          case Some(ver) =>
            IO(
              Console.err
                .println(s"✓ Found latest stable Scala 3 version: $ver")
            ).as(ver)
          case None =>
            IO(
              Console.err.println(
                s"⚠️ Could not fetch latest Scala version. Using offline fallback: $OfflineScalaVersion"
              )
            )
              .as(OfflineScalaVersion)
        }
      existingAnswers <- IO.blocking(readExistingAnswers(targetDir))
      features <- IO.blocking(
        detectExistingDefaults(
          targetDir,
          getFeaturesList(defaultScalaVersion),
          existingAnswers
        )
      )
    yield features

  private def projectExists(targetDir: os.Path): Boolean =
    os.exists(targetDir / "build.sc") || os.exists(
      targetDir / "build.sbt"
    ) || os.exists(targetDir / "project.scala")

  private def readExistingAnswers(targetDir: os.Path): Map[String, String] =
    val configPath = targetDir / ".agents" / "setup_config.json"
    if os.exists(configPath) then
      try ujson.read(os.read(configPath)).obj.map((k, v) => k -> v.str).toMap
      catch case _: Exception => Map.empty[String, String]
    else Map.empty[String, String]

  private def prepareAnswerLog(targetDir: os.Path, args: AgentArgs): IO[Unit] =
    val reset = if args.reset then AnswerLog.reset[IO](targetDir) else IO.unit
    reset *> args.inlineAnswers.fold(IO.unit) { inline =>
      AnswerLog
        .read[IO](targetDir)
        .flatMap(existing =>
          AnswerLog.write[IO](targetDir, AnswerLog.merge(existing, inline))
        )
    }

  private def emit(outcome: AgentMain.Outcome): IO[ExitCode] =
    IO.blocking {
      if outcome.stdout.nonEmpty then Console.out.println(outcome.stdout)
      if outcome.stderr.nonEmpty then Console.err.println(outcome.stderr)
    }.as(ExitCode(outcome.exitCode))

  private def setupFlow(
      targetDir: os.Path
  ): Flow[IO, List[Feature], Map[String, String]] =
    featuresInputFlow >>> ReplayAsk
      .askUntilValid[IO](targetDir, Validator.basic[IO]) >>> validAnswersFlow

  private val featuresInputFlow: Flow[IO, List[Feature], AskInput] =
    Flow.lift { features =>
      AskInput(
        features.map(featureQuestion),
        Some(
          "Select scala-llm-template setup options. Use each default unless the project clearly needs a different value."
        )
      )
    }

  private val validAnswersFlow: Flow[IO, ValidAnswers, Map[String, String]] =
    Flow.apply(valid => IO.pure(ValidAnswers.toMap(valid)))

  private def featureQuestion(feature: Feature): Question =
    Question(
      feature.id,
      feature.prompt,
      featureKind(feature),
      Some(feature.defaultValue),
      None,
      None
    )

  private def featureKind(feature: Feature): QuestionKind =
    feature.id match
      case "build-tool" => QuestionKind.Choice(List("mill", "sbt", "scala-cli"))
      case "scripts"    => QuestionKind.Choice(List("scala-cli", "none"))
      case "ecosystem"  => QuestionKind.Choice(List("typelevel", "zio", "none"))
      case "test-tools" =>
        QuestionKind.Choice(List("munit+shapeless", "zio-test", "none"))
      case "scala-version" => QuestionKind.FreeText
      case _               => QuestionKind.Choice(List("yes", "no"))

  private def writeProject(
      targetDir: os.Path,
      answers: Map[String, String]
  ): IO[ujson.Value] = IO.blocking {
    val finalScalaVer = answers.getOrElse("scala-version", OfflineScalaVersion)
    val ctx = SetupContext(targetDir, answers, finalScalaVer)
    val results = setupSteps.map { step =>
      Console.err.println(s"\n[setup:${step.id}]")
      step.run(ctx)
    }

    Console.err.println(s"\n=== Setup Completed Successfully! ===")
    Console.err.println(s"Project Location: $targetDir")
    Console.err.println(s"Selected Scala Version: $finalScalaVer")
    Console.err.println(
      s"Build Tool Configured: ${answers.getOrElse("build-tool", "mill").toUpperCase}"
    )

    ujson.Obj(
      "targetDir" -> targetDir.toString,
      "scalaVersion" -> finalScalaVer,
      "buildTool" -> answers.getOrElse("build-tool", "mill"),
      "steps" -> ujson.Arr(results.map(_.json)*)
    )
  }

  private def setupSteps: List[SetupStep] =
    List(
      SaveSetupConfig,
      InitializeProjectLayout,
      ConfigureStryker,
      RunSpecializedSetupScripts,
      InstallKit,
      FormatProject,
      StageGitChanges
    )

  private object SaveSetupConfig extends SetupStep:
    val id = "save-setup-config"

    def run(ctx: SetupContext): StepResult =
      os.makeDir.all(ctx.targetDir / ".agents")
      val configPath = ctx.targetDir / ".agents" / "setup_config.json"
      val configContent =
        ujson.Obj.from(ctx.answers.map((k, v) => k -> ujson.Str(v)))
      os.write.over(configPath, configContent.render(indent = 2))
      Console.err.println("✓ Saved configuration to .agents/setup_config.json")
      StepResult(
        id,
        "completed",
        "saved setup answers",
        List(configPath.toString)
      )

  private object InitializeProjectLayout extends SetupStep:
    val id = "initialize-project-layout"

    def run(ctx: SetupContext): StepResult =
      os.makeDir.all(ctx.targetDir / "app" / "src")
      os.makeDir.all(ctx.targetDir / "app" / "test" / "src")

      var files = List.empty[String]
      val gitignore = ctx.targetDir / ".gitignore"
      if !os.exists(gitignore) then
        os.write(
          gitignore,
          "out/\n.bsp/\n.metals/\n.vscode/\n.idea/\n.DS_Store\n"
        )
        files = files :+ gitignore.toString

      val scalafmt = ctx.targetDir / ".scalafmt.conf"
      if !os.exists(scalafmt) then
        os.write(scalafmt, "version = \"3.8.1\"\nrunner.dialect = scala3\n")
        files = files :+ scalafmt.toString
        Console.err.println("✓ Created Scalafmt configuration (.scalafmt.conf)")

      val scalafixConf = ctx.targetDir / ".scalafix.conf"
      if !os.exists(scalafixConf) then
        os.write(
          scalafixConf,
          "rules = [\n  OrganizeImports,\n  DisableSyntax,\n  LeakingImplicitClassVal,\n  NoValInForComprehension\n]\n"
        )
        files = files :+ scalafixConf.toString
        Console.err.println("✓ Created Scalafix configuration (.scalafix.conf)")

      val sdkmanrc = ctx.targetDir / ".sdkmanrc"
      if ctx.answers.getOrElse("sdkmanrc", "no").toLowerCase == "yes" then
        if !os.exists(sdkmanrc) then
          os.write(
            sdkmanrc,
            s"java=21.0.2-tem\nscala=${ctx.finalScalaVersion}\n"
          )
          files = files :+ sdkmanrc.toString
          Console.err.println("✓ Created SDKMAN! configuration (.sdkmanrc)")
      else if os.exists(sdkmanrc) then
        os.remove(sdkmanrc)
        files = files :+ sdkmanrc.toString
        Console.err.println("✓ Removed SDKMAN! configuration (.sdkmanrc)")

      val dockerfile = ctx.targetDir / "Dockerfile"
      if ctx.answers.getOrElse("docker", "no").toLowerCase == "yes" then
        if !os.exists(dockerfile) then
          val buildTool =
            ctx.answers.getOrElse("build-tool", "mill").toLowerCase
          val dockerContent = buildTool match {
            case "sbt" =>
              """# Stage 1: Build stage
                |FROM sbtscala/scala-sbt:eclipse-temurin-jammy-21.0.2_13.0.0_3.3.3 AS builder
                |WORKDIR /workspace
                |COPY . .
                |RUN sbt stage
                |
                |# Stage 2: Runtime stage
                |FROM eclipse-temurin:21-jre-jammy
                |WORKDIR /app
                |COPY --from=builder /workspace/target/universal/stage /app
                |EXPOSE 8080
                |ENTRYPOINT ["bin/app"]
                |""".stripMargin
            case "scala-cli" =>
              """# Stage 1: Build stage
                |FROM eclipse-temurin:21-jdk-jammy AS builder
                |WORKDIR /workspace
                |COPY . .
                |RUN curl -fLo scala-cli https://github.com/Virtuslab/scala-cli/releases/latest/download/scala-cli-x86_64-pc-linux.gz && \
                |    gunzip scala-cli && chmod +x scala-cli && ./scala-cli package . -o app.jar --assembly
                |
                |# Stage 2: Runtime stage
                |FROM eclipse-temurin:21-jre-jammy
                |WORKDIR /app
                |COPY --from=builder /workspace/app.jar /app/app.jar
                |EXPOSE 8080
                |ENTRYPOINT ["java", "-jar", "app.jar"]
                |""".stripMargin
            case _ => // mill
              """# Stage 1: Build stage
                |FROM eclipse-temurin:21-jdk-jammy AS builder
                |WORKDIR /workspace
                |COPY . .
                |RUN ./mill app.assembly
                |
                |# Stage 2: Runtime stage
                |FROM eclipse-temurin:21-jre-jammy
                |WORKDIR /app
                |COPY --from=builder /workspace/out/app/assembly.dest/out.jar /app/app.jar
                |EXPOSE 8080
                |ENTRYPOINT ["java", "-jar", "app.jar"]
                |""".stripMargin
          }
          os.write(dockerfile, dockerContent)
          files = files :+ dockerfile.toString
          Console.err.println("✓ Created Dockerfile configuration (Dockerfile)")
      else if os.exists(dockerfile) then
        os.remove(dockerfile)
        files = files :+ dockerfile.toString
        Console.err.println("✓ Removed Dockerfile configuration (Dockerfile)")

      val status = if files.isEmpty then "skipped" else "completed"
      val message =
        if files.isEmpty then "project layout already initialized"
        else "initialized project layout and base configuration"
      StepResult(id, status, message, files)

  private object ConfigureStryker extends SetupStep:
    val id = "configure-stryker"

    def run(ctx: SetupContext): StepResult =
      val strykerConf = ctx.targetDir / "stryker4s.conf"
      if ctx.answers.getOrElse("stryker", "no").toLowerCase == "yes" then
        if !os.exists(strykerConf) then
          os.write(
            strykerConf,
            "stryker4s {\n  mutate: [ \"app/src/**/*.scala\" ]\n  reporters: [\"html\", \"json\"]\n  thresholds {\n    high = 80\n    low = 60\n    break = 0\n  }\n  debug {\n    log-test-runner-stdout = true\n  }\n}\n"
          )
          Console.err.println(
            "✓ Created Stryker4s configuration (stryker4s.conf)"
          )
          StepResult(
            id,
            "completed",
            "created Stryker4s configuration",
            List(strykerConf.toString)
          )
        else StepResult(id, "skipped", "Stryker4s configuration already exists")
      else if os.exists(strykerConf) then
        os.remove(strykerConf)
        Console.err.println(
          "✓ Removed Stryker4s configuration (stryker4s.conf)"
        )
        StepResult(
          id,
          "completed",
          "removed Stryker4s configuration",
          List(strykerConf.toString)
        )
      else StepResult(id, "skipped", "Stryker4s disabled and no config exists")

  private object RunSpecializedSetupScripts extends SetupStep:
    val id = "run-specialized-setup-scripts"

    def run(ctx: SetupContext): StepResult =
      Console.err.println("\nRunning specialized setup scripts...")

      val scriptsDir = ctx.targetDir / "scripts"
      os.makeDir.all(scriptsDir)

      val useLocal = os.exists(os.pwd / "Setup.scala") && os.exists(
        os.pwd / "scripts" / "setup-build.scala"
      )

      val baseUrl =
        "https://raw.githubusercontent.com/MercurieVV/scala-llm-template/master/scripts"
      val scriptPaths = List(
        if useLocal then (os.pwd / "scripts" / "setup-build.scala").toString
        else s"$baseUrl/setup-build.scala",
        if useLocal then (os.pwd / "scripts" / "setup-git-hooks.scala").toString
        else s"$baseUrl/setup-git-hooks.scala",
        if useLocal then (os.pwd / "scripts" / "setup-llm-rules.scala").toString
        else s"$baseUrl/setup-llm-rules.scala",
        if useLocal then (os.pwd / "scripts" / "setup-mdoc.scala").toString
        else s"$baseUrl/setup-mdoc.scala"
      )

      if useLocal then Console.err.println("✓ Using local setup scripts cache")
      else
        Console.err.println(
          "✓ Running setup scripts directly from remote GitHub repository"
        )

      val childStdout =
        os.ProcessOutput.Readlines(line => Console.err.println(line))

      scriptPaths.foreach { script =>
        os.proc("scala-cli", "run", script, "--", ctx.targetDir.toString)
          .call(stdout = childStdout, stderr = os.Inherit)
      }

      StepResult(
        id,
        "completed",
        "ran delegated setup scripts",
        List(scriptsDir.toString)
      )

  /** The pure text half of the kit install: recipe-block extraction, the marked block, the Mill build patch and the
    * version facts a recipe pins. It holds no filesystem state and never sees a `SetupContext` — `InstallKit`
    * decides what to write and where.
    */
  private object KitText:
    /** Stable markers: a second run replaces the marked block rather than appending a second copy. */
    val MarkdownBegin = "<!-- reengineering-kit:begin -->"
    val MarkdownEnd   = "<!-- reengineering-kit:end -->"
    val CodeBegin     = "// >>> reengineering-kit:begin"
    val CodeEnd       = "// <<< reengineering-kit:end"

    /** Says out loud what the markers do: only the block itself is replaced, so wiring moved out of it comes back. */
    val BlockNote =
      "// Written and replaced by Setup.scala: wiring moved out of this block is re-added on the next run."

    /** Reads the fenced code blocks out of a recipe, in the order they appear. */
    def codeBlocks(markdown: String): List[CodeBlock] =
      var lang: Option[String] = None
      var buffer = List.empty[String]
      var blocks = List.empty[CodeBlock]
      markdown.linesIterator.foreach { line =>
        if line.startsWith("```") then
          lang match
            case Some(l) =>
              blocks = blocks :+ CodeBlock(l, buffer.reverse.mkString("\n"))
              buffer = Nil
              lang = None
            case None => lang = Some(line.drop(3).trim)
        else if lang.isDefined then buffer = line :: buffer
      }
      blocks.reverse

    /** The one fenced block of `recipe` tagged `lang` and containing `anchor`. A drifted recipe fails loudly here,
      * with the anchor and the recipe named, instead of installing half a wiring.
      */
    def block(
        blocks: List[CodeBlock],
        lang: String,
        anchor: String,
        recipe: String
    ): String =
      blocks
        .find(b => b.lang == lang && b.body.contains(anchor))
        .map(_.body)
        .getOrElse(
          throw new IllegalStateException(
            s"kit/recipes/$recipe has no '$lang' block containing '$anchor'"
          )
        )

    /** The version a recipe pins, read out of the block that carries it. A pattern that no longer matches is an
      * error naming the recipe and the pattern, for the same reason an anchor is: silently not knowing which pair
      * the wiring was measured against is how a wording change turns into a wrong install.
      */
    def versionIn(block: String, pattern: scala.util.matching.Regex, recipe: String): String =
      pattern
        .findFirstMatchIn(block)
        .map(_.group(1))
        .getOrElse(
          throw new IllegalStateException(
            s"kit/recipes/$recipe no longer matches ${pattern.regex}; the installer cannot tell which version its wiring was measured with"
          )
        )

    /** The per-module half of a recipe is the project's own decision (R-10), so its example is installed commented,
      * beside the mechanism it configures, instead of guessing module names.
      */
    def asTemplate(title: String, block: String): String =
      s"// $title\n" + block.linesIterator
        .map { line =>
          if line.trim.isEmpty then "//"
          else if line.trim.startsWith("//") then line
          else s"// $line"
        }
        .mkString("\n")

    def markCode(body: String): String =
      s"$CodeBegin\n$BlockNote\n$body\n$CodeEnd\n"

    def plantCodeBlock(existing: String, body: String): String =
      replaceOrAppend(existing, CodeBegin, CodeEnd, markCode(body))

    /** Plants `block` between the markers, replacing the marked span when the file already carries one, so a second
      * run never appends a second copy.
      */
    def replaceOrAppend(
        existing: String,
        begin: String,
        end: String,
        block: String
    ): String =
      val start = existing.indexOf(begin)
      if start < 0 then
        if existing.isEmpty then block
        else existing.stripLineEnd + "\n\n" + block
      else
        val close = existing.indexOf(end, start)
        if close < 0 then existing.substring(0, start) + block
        else
          val tail = existing.substring(close + end.length).dropWhile(_ == '\n')
          existing.substring(0, start) + block + tail

    /** The file without the marked span: what the *project* declared, as opposed to what a previous run planted. */
    def outsideMarkedBlock(text: String, begin: String, end: String): String =
      val start = text.indexOf(begin)
      if start < 0 then text
      else
        val close = text.indexOf(end, start)
        if close < 0 then text.substring(0, start)
        else text.substring(0, start) + text.substring(close + end.length)

    /** Adds only what the Mill build is missing — the mill-scalafix build dependency, the `package build` line and
      * the two imports — then plants (or replaces) the marked block that carries `BuildPaths`, the `scalafixRules`
      * module, the tool-classpath trait and the mix-in template.
      */
    def patchMillBuild(
        existing: String,
        depLines: List[String],
        packageLine: String,
        importLines: List[String],
        body: String
    ): String =
      val lines = existing.linesIterator.toList
      val headerEnd = lines.takeWhile(_.startsWith("//|")).size
      val header = lines.take(headerEnd)
      // The guard reads the directive region — the `//|` header — not the whole file: a body comment that mentions
      // mill-scalafix must not stop the build dependency from being declared.
      val withHeader =
        if header.exists(_.contains("mill-scalafix")) then existing
        else
          val (at, inject) = millMvnDepsInjection(header, depLines)
          (lines.take(at) ++ inject ++ lines.drop(at)).mkString("\n") + "\n"
      val withPackage =
        if withHeader.linesIterator.exists(_.trim == packageLine) then withHeader
        else insertAfterHeader(withHeader, packageLine)
      val withImports = importLines.foldLeft(withPackage) { (text, line) =>
        if text.contains(line) then text else insertAfterImports(text, line)
      }
      plantCodeBlock(withImports, body)

    /** Where the mill-scalafix `//|` entries go in a Mill YAML header, and where they do not. Mill reads a
      * `build.mill` header as YAML, so an entry is a dependency only when it sits under the `mvnDeps:` key:
      *
      *   - header names `mvnDeps:` as a block list → after the last of that key's items (`- …`, or a continuation
      *     comment/blank line), before the next key;
      *   - header names other keys only (or there is no header) → a new `mvnDeps:` key at the end of the header
      *     (position 0 when there is none);
      *   - header names `mvnDeps:` with an inline flow list → inside its brackets.
      *
      * Appending after the whole header — what this replaced — put the entry under whichever key came last, where it
      * is that key's value and declares no dependency at all.
      */
    private def millMvnDepsInjection(
        header: List[String],
        depLines: List[String]
    ): (Int, List[String]) =
      val keyAt = header.lastIndexWhere(_.trim.startsWith("//| mvnDeps:"))
      if keyAt < 0 then (header.size, "//| mvnDeps:" :: depLines)
      else
        val value = header(keyAt).trim.stripPrefix("//| mvnDeps:").trim
        if value.isEmpty then
          // The items already under the key: `- …` entries plus any continuation comment or blank `//|` line.
          val items = header
            .drop(keyAt + 1)
            .takeWhile { line =>
              val item = line.stripPrefix("//|").trim
              item.isEmpty || item.startsWith("-") || item.startsWith("#")
            }
            .size
          (keyAt + 1 + items, depLines)
        else if value.startsWith("[") && value.endsWith("]") then
          val coords = depLines.map(_.stripPrefix("//|").trim.stripPrefix("-").trim)
          val inside = value.drop(1).dropRight(1).trim
          val merged = if inside.isEmpty then coords else inside :: coords
          (keyAt, List(s"//| mvnDeps: [${merged.mkString(", ")}]"))
        else
          throw new IllegalStateException(
            s"build.mill's 'mvnDeps:' header line carries a value this installer cannot extend: ${header(keyAt)}"
          )

    private def insertAfterHeader(text: String, line: String): String =
      val lines = text.linesIterator.toList
      val headerEnd = lines.takeWhile(_.startsWith("//|")).size
      (lines.take(headerEnd) ++ List(line) ++ lines.drop(headerEnd))
        .mkString("\n") + "\n"

    private def insertAfterImports(text: String, line: String): String =
      val lines = text.linesIterator.toList
      val lastImport = lines.lastIndexWhere(_.trim.startsWith("import "))
      val packageAt = lines.lastIndexWhere(_.trim.startsWith("package "))
      val at =
        if lastImport >= 0 then lastImport + 1
        else if packageAt >= 0 then packageAt + 1
        else lines.takeWhile(_.startsWith("//|")).size
      (lines.take(at) ++ List(line) ++ lines.drop(at)).mkString("\n") + "\n"

  /** The reengineering kit: the `AllowedShape` rule, the wiring the chosen recipe states, the five skills and the
    * digest block. Every file it writes is read from `kit/` at run time — the rule, its registration, the Mill
    * helper, the recipes' own code blocks, the skills and the digest — so no recipe or rule text is duplicated here.
    * The text mechanics live in `KitText`; this step decides what to write, where, and what to say about it.
    *
    * Inserted after `RunSpecializedSetupScripts` (the build files exist by then, and the Mill and sbt wiring patch
    * them) and before `FormatProject`, so what it writes is formatted and staged with everything else.
    */
  private object InstallKit extends SetupStep:
    val id = "install-kit"

    /** The five skill directories `kit/skills/` ships; the digest names the same five. */
    private val SkillNames = List(
      "shaping-a-module",
      "reengineering-module",
      "reshaping-module-by-linters",
      "verify-before-done",
      "verification-lane"
    )

    /** Where each recipe states the Scala version and the scalafix version its wiring was measured with. Reading
      * them out of the recipe keeps the fact in one place; a recipe that stops matching fails the install
      * (`KitText.versionIn`) instead of leaving the installer quietly unable to say what it installed.
      */
    private val MillScalaVersion = """val scala3Version\s*=\s*"([^"]+)"""".r
    private val MillScalafixVersion =
      """scalafix-rules_[0-9.]+:([0-9]+\.[0-9]+\.[0-9]+)""".r
    private val SbtScalaVersion =
      """ThisBuild / scalaVersion\s*:=\s*"([^"]+)"""".r
    private val SbtPluginVersion =
      """sbt-scalafix"\s*%\s*"([0-9]+\.[0-9]+\.[0-9]+)"""".r
    private val SbtScalafixVersion =
      """"scalafix-rules"\s*%\s*"([0-9]+\.[0-9]+\.[0-9]+)"""".r
    private val CliScalaVersion = """SCALA=([0-9]+\.[0-9]+\.[0-9]+)""".r
    private val CliScalafixVersion = """SCALAFIX=([0-9]+\.[0-9]+\.[0-9]+)""".r

    def run(ctx: SetupContext): StepResult =
      if ctx.answers.getOrElse("kit", "no").toLowerCase != "yes" then
        StepResult(id, "skipped", "kit not selected")
      else
        findKitRoot() match
          case None =>
            Console.err.println(
              "⚠ kit was selected, but no kit/ directory was found at or above the working directory."
            )
            StepResult(
              id,
              "failed",
              "kit sources not found: the kit feature installs from a local checkout of scala-llm-template " +
                "(run Setup.scala from that checkout, as its own instructions do for a local script) — the rule, " +
                "the recipes and the skills are read from the checkout's kit/ directory at run time, so the remote " +
                "one-liner that fetches Setup.scala alone cannot install them"
            )
          case Some(kit) =>
            val buildTool =
              ctx.answers.getOrElse("build-tool", "mill").toLowerCase
            try
              val written = install(kit, ctx, buildTool)
              Console.err.println(
                s"✓ Vendored the reengineering kit for $buildTool (${written.size} files)"
              )
              StepResult(
                id,
                "completed",
                s"vendored the kit rule, wiring and skills for $buildTool",
                written
              )
            catch
              case e: Exception =>
                Console.err.println(s"⚠ kit install failed: ${e.getMessage}")
                StepResult(id, "failed", s"kit install failed: ${e.getMessage}")

    /** `kit/` sits beside `Setup.scala`, and the installer may be started from anywhere, so the search walks up
      * from the working directory — the same local-or-nothing choice `RunSpecializedSetupScripts` makes for its
      * scripts. A run from outside a checkout has no kit to read, and says so rather than installing nothing.
      */
    private def findKitRoot(): Option[os.Path] =
      @annotation.tailrec
      def loop(dir: os.Path): Option[os.Path] =
        if os.exists(dir / "kit" / "arhitecture-shape" / "AllowedShape.scala")
        then Some(dir / "kit")
        else
          val parent = dir / os.up
          if parent == dir then None else loop(parent)
      loop(os.pwd)

    private def install(
        kit: os.Path,
        ctx: SetupContext,
        buildTool: String
    ): List[String] =
      var files = List.empty[String]

      def write(rel: String, content: String): Unit =
        val path = ctx.targetDir / os.RelPath(rel)
        os.makeDir.all(path / os.up)
        os.write.over(path, content)
        files = files :+ path.toString

      /** A copy of kit text the project owns once it lands. The kit is **vendored**: the design's L2 says a project
        * may tune its copy, so a re-install must not destroy that tuning silently. Differing content is left exactly
        * where it is and the kit's version goes beside it as `<name>.kit-new`, named on stderr; identical content is
        * rewritten in place, so an untouched re-install stays idempotent.
        *
        * The files the installer owns instead — the marked blocks in `build.mill`/`build.sbt`/`AGENTS.md`/
        * `scala-rules.md`, `project/plugins.sbt`, `.scalafix.conf` and the copies it derives from the target's own
        * build — keep using `write`: replacing them is the install's job, and the target's own text in them is
        * preserved by construction (a marked span is replaced, a missing line is added).
        */
      def writeVendored(rel: String, content: String): Unit =
        val path = ctx.targetDir / os.RelPath(rel)
        if os.exists(path) && os.read(path) != content then
          val beside = path / os.up / (path.last + ".kit-new")
          os.makeDir.all(path / os.up)
          os.write.over(beside, content)
          files = files :+ beside.toString
          Console.err.println(
            s"⚠ $rel differs from the kit's copy (a tuned vendored file): it was left as it is and the kit's version written to $beside — diff the two and merge by hand; the kit never overwrites tuned content."
          )
        else write(rel, content)

      def readKit(rel: String): String =
        val path = kit / os.RelPath(rel)
        if !os.exists(path) then
          throw new IllegalStateException(s"kit file missing: kit/$rel")
        os.read(path)

      /** The enforcement README is what the digest points at: the schema, the symbol-prefix semantics and the rule's
        * named blind spot live there, and the digest restates none of them. Only `scala-cli.md`'s tree copies the
        * kit's whole directory; the Mill and sbt branches vendor the README without `check.sh` and `fixtures/`, so
        * the note appended here says which parts are in this project and where the rest lives. That keeps the
        * digest's pointer honest without restructuring the README's own content.
        */
      def writeReadme(): Unit =
        writeVendored(
          ".kit/arhitecture-shape/README.md",
          readKit("arhitecture-shape/README.md").stripLineEnd + "\n\n" + readmeNote()
        )

      /** Tool-aware, appended to the vendored README: which pieces of `arhitecture-shape/` this project has, and
        * where `check.sh` and its fixtures are for a project that did not get them.
        */
      def readmeNote(): String =
        val checkout = "`scala-llm-template` checkout, under `kit/arhitecture-shape/`"
        val runIt =
          "run it from that checkout: `sh <checkout>/kit/arhitecture-shape/check.sh --config <policy>`"
        val lines = buildTool match
          case "scala-cli" => List(
            "## What is present in this project",
            "",
            "Appended by `Setup.scala`'s kit step (the README above is the kit's own text). This project carries the " +
              "whole directory at `.kit/arhitecture-shape/`: this README, `AllowedShape.scala`, its registration, " +
              "`check.sh` and `fixtures/`.",
            "The project's own lint runner is `allowed-shape.sh` with a `shape-policy/<dir>.conf` per shaped " +
              "directory; `check.sh` is the kit's own fixture check, not that runner."
          )
          case "mill" => List(
            "## What is present in this project",
            "",
            "Appended by `Setup.scala`'s kit step (the README above is the kit's own text). This project carries the " +
              "rule and its wiring: `scalafixRules/src/AllowedShape.scala` with its `META-INF/services/scalafix.v1.Rule` " +
              "registration, `buildKit/ArchitectureShapeModule.mill`, `ScalafixExtra.mill` and the marked block in " +
              "`build.mill`.",
            s"`check.sh` and `fixtures/` are **not** vendored here — they live in the $checkout, together with this " +
              s"README; $runIt.",
            "The project's per-module policy lives in `build.mill`, not in this directory: the Mill recipe in that " +
              "checkout, `kit/recipes/mill.md`, states the wiring."
          )
          case _ => List(
            "## What is present in this project",
            "",
            "Appended by `Setup.scala`'s kit step (the README above is the kit's own text). This project carries the " +
              "rule and its wiring: `scalafix-rules/src/main/scala/AllowedShape.scala` with its " +
              "`META-INF/services/scalafix.v1.Rule` registration, the `sbt-scalafix` plugin line in " +
              "`project/plugins.sbt` and the marked block in `build.sbt`.",
            s"`check.sh` and `fixtures/` are **not** vendored here — they live in the $checkout, together with this " +
              s"README; $runIt.",
            "The project's per-module policy lives in each module's own `.scalafix.conf`: the sbt recipe in that " +
              "checkout, `kit/recipes/sbt.md`, states the wiring."
          )
        lines.mkString("\n") + "\n"

      val millBlocks = KitText.codeBlocks(readKit("recipes/mill.md"))
      val sbtBlocks  = KitText.codeBlocks(readKit("recipes/sbt.md"))
      val cliBlocks  = KitText.codeBlocks(readKit("recipes/scala-cli.md"))

      def installMill(): (String, String, Boolean) =
        val head = KitText.block(millBlocks, "scala", "object BuildPaths", "mill.md")
        // Read the pair the recipe was measured with before writing anything: a recipe that drifted must fail here,
        // not complete with wiring the installer only half understands.
        val measuredScala = KitText.versionIn(head, MillScalaVersion, "mill.md")
        val measuredScalafix = KitText.versionIn(head, MillScalafixVersion, "mill.md")
        val (fileLevel, declarations) =
          head.linesIterator.toList.span(l => !l.trim.startsWith("val scala3Version"))
        val depLines = fileLevel.filter(l => l.startsWith("//|") && l.trim != "//| mvnDeps:")
        val importLines = fileLevel.filter(_.trim.startsWith("import "))
        val packageLine = fileLevel
          .find(_.trim.startsWith("package "))
          .map(_.trim)
          .getOrElse("package build")

        writeVendored(
          "scalafixRules/src/AllowedShape.scala",
          readKit("arhitecture-shape/AllowedShape.scala")
        )
        writeVendored(
          "scalafixRules/resources/META-INF/services/scalafix.v1.Rule",
          readKit("arhitecture-shape/META-INF/services/scalafix.v1.Rule")
        )
        val helper = readKit("recipes/mill/ArchitectureShapeModule.mill")
        writeVendored("buildKit/ArchitectureShapeModule.mill", helper)
        // The anchor file carries just the helper's own package line, so the two cannot disagree.
        writeVendored("buildKit/package.mill", helper.linesIterator.next() + "\n")
        writeReadme()
        // The generic half of the wiring the helper mixes in: ExtraScalafixRules, ScalafixValue, RuleSettings.
        writeVendored(
          "ScalafixExtra.mill",
          KitText.block(millBlocks, "scala", "trait ExtraScalafixRules", "mill.md") + "\n"
        )
        if !os.exists(ctx.targetDir / ".scalafix.conf") then
          write(
            ".scalafix.conf",
            KitText.block(millBlocks, "hocon", "rules = []", "mill.md") + "\n"
          )

        val layer =
          KitText.block(millBlocks, "scala", "scalafixToolClasspath", "mill.md")
        val mixin = KitText.asTemplate(
          "Adapt this to the project's shaped modules — the kit cannot know which modules they are, " +
            "and the policy is per module (R-10).",
          KitText.block(millBlocks, "scala", "object engine extends Module", "mill.md")
        )
        val buildMill = ctx.targetDir / "build.mill"
        // The check must ignore the marked block: after a first run the kit's own `val scala3Version` is in there,
        // and reading it as the project's would drop it on the second run and break `scalafixRules`.
        val targetHasScalaVersion =
          os.exists(buildMill) &&
            KitText
              .outsideMarkedBlock(
                os.read(buildMill),
                KitText.CodeBegin,
                KitText.CodeEnd
              )
              .contains("val scala3Version")
        // A `build.sc` is what Mill 0.12 read; Mill 1.x reads `build.mill` only, so a project that has one and no
        // `build.mill` is told where its modules belong rather than being silently split across two build files.
        val notice =
          if os.exists(ctx.targetDir / "build.sc") then
            List(
              "// Notice: Mill 1.x reads build.mill, not build.sc — the build.sc left in this project is",
              "// ignored by Mill, and the project's own modules belong in this file or in sibling .mill files."
            ).mkString("\n")
          else ""
        val body = List(
          if targetHasScalaVersion then "" else declarations.headOption.getOrElse(""),
          declarations.drop(1).mkString("\n").stripLeading(),
          layer,
          mixin,
          notice
        ).filter(_.nonEmpty).mkString("\n\n")

        if os.exists(buildMill) then
          write(
            "build.mill",
            KitText.patchMillBuild(
              os.read(buildMill),
              depLines,
              packageLine,
              importLines,
              body
            )
          )
          Console.err.println("✓ Patched the Mill build (build.mill)")
        else
          write(
            "build.mill",
            fileLevel.mkString("\n").stripLineEnd + "\n\n" + KitText.markCode(body)
          )
          Console.err.println("✓ Wrote the Mill wiring (build.mill)")
          if os.exists(ctx.targetDir / "build.sc") then
            Console.err.println(
              "⚠ Mill 1.x reads build.mill, not build.sc: the build.mill just written sits beside this project's " +
                "build.sc, which Mill ignores — move the project's modules into build.mill (or a sibling .mill file)."
            )
        Console.err.println(
          "→ Mix `Layer with ArchitectureShapeModule` into each shaped module (see the marked block in build.mill)."
        )
        // The rule module follows the project's `val scala3Version` when the project declares one (the marked block
        // then omits the kit's declaration), so the measured pair is pinned only when this run wrote that declaration.
        (measuredScala, measuredScalafix, !targetHasScalaVersion)

      def installSbt(): (String, String, Boolean) =
        val semanticDb =
          KitText.block(sbtBlocks, "scala", "semanticdbEnabled", "sbt.md")
        val ruleProject = KitText.block(
          sbtBlocks,
          "scala",
          "disablePlugins(ScalafixPlugin)",
          "sbt.md"
        )
        val measuredScala =
          KitText.versionIn(semanticDb, SbtScalaVersion, "sbt.md")
        val measuredScalafix =
          KitText.versionIn(ruleProject, SbtScalafixVersion, "sbt.md")

        writeVendored(
          "scalafix-rules/src/main/scala/AllowedShape.scala",
          readKit("arhitecture-shape/AllowedShape.scala")
        )
        writeVendored(
          "scalafix-rules/src/main/resources/META-INF/services/scalafix.v1.Rule",
          readKit("arhitecture-shape/META-INF/services/scalafix.v1.Rule")
        )
        writeReadme()

        val pluginLine =
          KitText.block(sbtBlocks, "scala", "addSbtPlugin", "sbt.md").trim
        val measuredPlugin =
          KitText.versionIn(pluginLine, SbtPluginVersion, "sbt.md")
        val pluginsFile = ctx.targetDir / "project" / "plugins.sbt"
        val plugins = if os.exists(pluginsFile) then os.read(pluginsFile) else ""
        if !plugins.contains("sbt-scalafix") then
          write(
            "project/plugins.sbt",
            plugins.stripLineEnd + (if plugins.isEmpty then "" else "\n") + pluginLine + "\n"
          )
          Console.err.println("✓ Added sbt-scalafix to project/plugins.sbt")
        else
          // Presence alone says nothing: an older plugin loads a different scalafix CLI, so the wiring planted in
          // build.sbt was never measured against it. Warn like the Scala-version mismatch does.
          warnOnDeclaredSbtPlugin(
            plugins,
            measuredPlugin,
            measuredScala,
            measuredScalafix
          )

        val body = List(
          semanticDb,
          ruleProject,
          KitText.asTemplate(
            "Each shaped module opts in like this and states its own policy (R-10).",
            KitText.block(sbtBlocks, "scala", "lazy val mymodule", "sbt.md")
          )
        ).mkString("\n\n")
        val buildSbt = ctx.targetDir / "build.sbt"
        write(
          "build.sbt",
          KitText.plantCodeBlock(
            if os.exists(buildSbt) then os.read(buildSbt) else "",
            body
          )
        )
        Console.err.println("✓ Patched the sbt build (build.sbt)")
        Console.err.println(
          "→ Each shaped module opts in with `.dependsOn(`scalafix-rules` % ScalafixConfig)` and carries its own " +
            ".scalafix.conf (see the marked block in build.sbt)."
        )
        // The planted marked block declares `ThisBuild / scalaVersion` itself, so the rule project and the CLI
        // sbt-scalafix resolves for a module are the measured ones.
        (measuredScala, measuredScalafix, true)

      def installScalaCli(): (String, String, Boolean) =
        // scala-cli.md's tree copies the kit's whole `arhitecture-shape/` directory in as-is, under `.kit/` so the
        // project's own `scala-cli compile .` cannot pick the rule up (it is compiled against scalafix, not the
        // project). The README the digest points at travels with it, with the tool-aware note writeReadme appends.
        val shapeDir = kit / "arhitecture-shape"
        os.walk(shapeDir)
          .filter(os.isFile)
          .filterNot(_.last == "README.md")
          .foreach { path =>
            writeVendored(
              s".kit/arhitecture-shape/${path.relativeTo(shapeDir)}",
              os.read(path)
            )
          }
        writeReadme()
        val runner =
          KitText.block(cliBlocks, "sh", "RULE_DIR=.kit/arhitecture-shape", "scala-cli.md")
        writeVendored("allowed-shape.sh", runner + "\n")
        Console.err.println("✓ Wrote the scala-cli wiring (allowed-shape.sh)")
        Console.err.println(
          "→ Run it per shaped directory: sh allowed-shape.sh <sources-dir> <config-file> — the config is that directory's own policy."
        )
        // `SCALA=` is a literal in the runner, so the measured pair is pinned by what this run wrote.
        (
          KitText.versionIn(runner, CliScalaVersion, "scala-cli.md"),
          KitText.versionIn(runner, CliScalafixVersion, "scala-cli.md"),
          true
        )

      val (measuredScala, measuredScalafix, pinned) = buildTool match
        case "mill"      => installMill()
        case "sbt"       => installSbt()
        case "scala-cli" => installScalaCli()
        case other =>
          throw new IllegalArgumentException(
            s"unknown build-tool '$other' (expected mill, sbt or scala-cli)"
          )
      warnOnMeasuredPair(ctx, buildTool, measuredScala, measuredScalafix, pinned)

      SkillNames.foreach { name =>
        writeVendored(s".dsh/skills/$name/SKILL.md", readKit(s"skills/$name/SKILL.md"))
      }

      val digest = readKit("digest.md").stripLineEnd
      val digestBlock =
        s"${KitText.MarkdownBegin}\n$digest\n${KitText.MarkdownEnd}\n"
      val digestTargets =
        "AGENTS.md" :: List(".agents/AGENTS.md", "scala-rules.md")
          .filter(rel => os.exists(ctx.targetDir / os.RelPath(rel)))
      digestTargets.foreach { rel =>
        val path = ctx.targetDir / os.RelPath(rel)
        val existing = if os.exists(path) then os.read(path) else ""
        write(
          rel,
          KitText.replaceOrAppend(
            existing,
            KitText.MarkdownBegin,
            KitText.MarkdownEnd,
            digestBlock
          )
        )
      }
      Console.err.println(
        s"✓ Planted the kit digest in ${digestTargets.mkString(", ")}"
      )

      files

    /** The recipes' wiring is measured against one published pair — a Scala version and the scalafix version whose
      * CLI loads the rule — and the installer leaves that pair intact rather than generalising half of it: rewriting
      * only the Scala version would install wiring whose artifacts do not resolve (measured: `scalafix-rules_3.9.0`
      * publishes 0.14.8 and 0.14.9, not the recipes' 0.14.7). When the project's own answer differs, the step says so
      * loudly instead of installing something that cannot build — and it says *which* install it is talking about:
      * `pinned` is whether this run wrote the Scala-version literal the rule module compiles at.
      */
    private def warnOnMeasuredPair(
        ctx: SetupContext,
        buildTool: String,
        measuredScala: String,
        measuredScalafix: String,
        pinned: Boolean
    ): Unit =
      if ctx.finalScalaVersion != measuredScala then
        val location = buildTool match
          case "mill" => "`val scala3Version` in build.mill"
          case "sbt"  => "`ThisBuild / scalaVersion` in build.sbt"
          case _      => "`SCALA=` in allowed-shape.sh"
        val remedy =
          s"""  To build the rule for this project's own Scala version, raise the pair together: $location, and the scalafix version (ch.epfl.scala:scalafix-rules_${ctx.finalScalaVersion} for the build, ch.epfl.scala:scalafix-cli_${ctx.finalScalaVersion} for the CLI that loads it).
             |  Check the coordinate on Maven Central first — Scala 3.9.0, for instance, has 0.14.8 and 0.14.9 but no $measuredScalafix.""".stripMargin
        if pinned then
          Console.err.println(
            s"""
               |⚠ scala-version = ${ctx.finalScalaVersion}, but the kit's rule wiring is measured against Scala $measuredScala with scalafix $measuredScalafix.
               |  The wiring pins that measured pair deliberately — the two are published together — so what was just installed resolves and compiles as it stands.
               |$remedy
               |""".stripMargin
          )
        else
          val depLiteral = s"scalafix-rules_${measuredScala}:${measuredScalafix}"
          Console.err.println(
            s"""
               |⚠ scala-version = ${ctx.finalScalaVersion}, but the kit's rule wiring is measured against Scala $measuredScala with scalafix $measuredScalafix.
               |  This project already declares its own Scala version, so the installer left that declaration alone: the rule module follows the project's Scala version ${ctx.finalScalaVersion}, while its dependency still says ch.epfl.scala:$depLiteral — and mill-scalafix resolves its CLI from the linted module's version (${ctx.finalScalaVersion}). This install therefore does NOT resolve and compile as it stands.
               |  Change both literals together: the project's own Scala-version declaration, and the dependency literal `ch.epfl.scala:$depLiteral` in the marked `scalafixRules` block of build.mill (${ctx.finalScalaVersion} then resolves the CLI as ch.epfl.scala:scalafix-cli_${ctx.finalScalaVersion}:<same version>).
               |  Check the coordinate on Maven Central first — Scala 3.9.0, for instance, has 0.14.8 and 0.14.9 but no $measuredScalafix.
               |""".stripMargin
          )

    /** The sbt plugin line is the other measured literal: the recipe's `addSbtPlugin(… "sbt-scalafix" % "<version>")`
      * is what the block planted in `build.sbt` was executed against, and an older plugin brings a different scalafix
      * CLI. A target that already declares sbt-scalafix is therefore not "done" — when the declared version differs
      * (or cannot be read), the step says which version is there, which one the wiring was measured with, and what to
      * change.
      */
    private def warnOnDeclaredSbtPlugin(
        plugins: String,
        measuredPlugin: String,
        measuredScala: String,
        measuredScalafix: String
    ): Unit =
      val declared =
        SbtPluginVersion.findAllMatchIn(plugins).map(_.group(1)).toList.distinct
      if declared.isEmpty then
        Console.err.println(
          s"""
             |⚠ project/plugins.sbt names sbt-scalafix, but the installer could not read a version literal from it, so it cannot tell whether the plugin matches the wiring it just wrote.
             |  The sbt block planted in build.sbt (Scala $measuredScala, scalafix $measuredScalafix) was measured with sbt-scalafix $measuredPlugin; a different plugin version loads a different scalafix CLI.
             |  Make sure the declared plugin is that one: addSbtPlugin("ch.epfl.scala" % "sbt-scalafix" % "$measuredPlugin").
             |""".stripMargin
        )
      else if !declared.contains(measuredPlugin) then
        Console.err.println(
          s"""
             |⚠ project/plugins.sbt declares sbt-scalafix ${declared.mkString(", ")}, but the kit's sbt wiring was measured with $measuredPlugin.
             |  The block just planted in build.sbt (Scala $measuredScala, scalafix $measuredScalafix, the rule project and the per-module ScalafixConfig opt-in) was executed against sbt-scalafix $measuredPlugin; ${declared.mkString(", ")} loads a different scalafix CLI, so the wiring does not resolve as it stands.
             |  Raise it: project/plugins.sbt — addSbtPlugin("ch.epfl.scala" % "sbt-scalafix" % "$measuredPlugin").
             |""".stripMargin
        )

  private object FormatProject extends SetupStep:
    val id = "format-project"

    def run(ctx: SetupContext): StepResult =
      try
        Console.err.println("Formatting project files (Scalafmt)...")
        os.proc("scala-cli", "fmt", ".")
          .call(cwd = ctx.targetDir, stdout = os.Pipe, stderr = os.Pipe)
        StepResult(id, "completed", "formatted project files")
      catch
        case _: Exception =>
          StepResult(id, "skipped", "Scalafmt failed or was unavailable")

  private object StageGitChanges extends SetupStep:
    val id = "stage-git-changes"

    def run(ctx: SetupContext): StepResult =
      val childStdout =
        os.ProcessOutput.Readlines(line => Console.err.println(line))
      if !os.exists(ctx.targetDir / ".git") then
        os.proc("git", "init")
          .call(cwd = ctx.targetDir, stdout = childStdout, stderr = os.Inherit)
      os.proc("git", "add", ".")
        .call(cwd = ctx.targetDir, stdout = childStdout, stderr = os.Inherit)
      StepResult(id, "completed", "staged project changes in Git")

  def fetchLatestStableVersion(
      group: String,
      artifact: String
  ): Option[String] =
    val groupPath = group.replace('.', '/')
    val url =
      s"https://repo1.maven.org/maven2/$groupPath/$artifact/maven-metadata.xml"
    try
      val p = os
        .proc("curl", "-fsSL", "--connect-timeout", "3", url)
        .call(stderr = os.Pipe)
      val xml = if p.exitCode == 0 then p.out.text()
      else throw new RuntimeException("Fetch failed")
      val versionRegex = """<version>([^<]+)</version>""".r
      val versions = versionRegex.findAllMatchIn(xml).map(_.group(1)).toList
      val stableVersions = versions.filter(_.matches("^[0-9]+(\\.[0-9]+)*$"))
      if stableVersions.nonEmpty then Some(stableVersions.last)
      else
        val ReleaseRegex = """<release>([^<]+)</release>""".r
        val LatestRegex = """<latest>([^<]+)</latest>""".r
        ReleaseRegex
          .findFirstMatchIn(xml)
          .map(_.group(1))
          .orElse(LatestRegex.findFirstMatchIn(xml).map(_.group(1)))
    catch case _: Exception => None

  def promptFeaturesGrouped(features: List[Feature]): Map[String, String] =
    val grouped = features.groupBy(_.group)
    val orderedGroups = List(
      "Core",
      "Ecosystem",
      "Quality Assurance",
      "Data Utilities",
      "Developer Tooling"
    )
    var answers = Map.empty[String, String]

    orderedGroups.foreach { groupName =>
      grouped.get(groupName).foreach { list =>
        println(s"\n--- $groupName Options ---")
        list.foreach { f =>
          val rawInput = readLine(
            s"  ${f.name} [${f.prompt}] (default: ${f.defaultValue}): "
          )
          val response = if rawInput == null then "" else rawInput.trim
          val finalVal = if response.isEmpty then f.defaultValue else response
          answers = answers + (f.id -> finalVal)
        }
      }
    }
    answers

  def detectExistingDefaults(
      target: os.Path,
      features: List[Feature],
      existingAnswers: Map[String, String]
  ): List[Feature] =
    val buildScFile = target / "build.sc"
    val buildSbtFile = target / "build.sbt"
    val projectScalaFile = target / "project.scala"

    val buildScContent =
      if os.exists(buildScFile) then os.read(buildScFile) else ""
    val buildSbtContent =
      if os.exists(buildSbtFile) then os.read(buildSbtFile) else ""
    val projectScalaContent =
      if os.exists(projectScalaFile) then os.read(projectScalaFile) else ""
    val combinedBuildContent =
      buildScContent + "\n" + buildSbtContent + "\n" + projectScalaContent

    features.map { f =>
      val defaultValue = if existingAnswers.contains(f.id) then
        existingAnswers(f.id)
      else
        f.id match
          case "build-tool" =>
            if os.exists(buildScFile) then "mill"
            else if os.exists(buildSbtFile) then "sbt"
            else if os.exists(projectScalaFile) then "scala-cli"
            else f.defaultValue

          case "scala-version" =>
            val scalaVerRegex =
              """(?:def\s+scalaVersion\s*=\s*"|scalaVersion\s*:=\s*")([^"]+)"""".r
            scalaVerRegex.findFirstMatchIn(combinedBuildContent) match
              case Some(m) => m.group(1)
              case None    => f.defaultValue

          case "cross-version" =>
            val hasCross = combinedBuildContent.contains("CrossScalaModule") ||
              combinedBuildContent.contains("crossScalaVersions") ||
              combinedBuildContent.contains("Cross[AppModule]")
            if hasCross then "yes" else "no"

          case "scripts" =>
            if os.exists(projectScalaFile) && !os.exists(buildScFile) && !os
                .exists(buildSbtFile)
            then "none"
            else if os.exists(projectScalaFile) then "scala-cli"
            else "none"

          case "github-flow" =>
            if os.exists(target / ".github" / "workflows" / "ci.yml") then "yes"
            else "no"

          case "ecosystem" =>
            if combinedBuildContent.contains("cats-core") then "typelevel"
            else if combinedBuildContent.contains("zio") then "zio"
            else "none"

          case "web-server" =>
            val hasWebServer = combinedBuildContent.contains(
              "http4s-ember-server"
            ) || combinedBuildContent.contains("zio-http")
            if hasWebServer then "yes" else "no"

          case "web-client" =>
            val hasWebClient = combinedBuildContent.contains(
              "http4s-ember-client"
            ) || combinedBuildContent.contains("sttp.client")
            if hasWebClient then "yes" else "no"

          case "db-access" =>
            val hasDb = combinedBuildContent.contains(
              "doobie"
            ) || combinedBuildContent.contains(
              "quill-jdbc"
            ) || combinedBuildContent.contains("postgresql")
            if hasDb then "yes" else "no"

          case "serverless-run" =>
            if combinedBuildContent.contains("aws-lambda-java-core") then "yes"
            else "no"

          case "test-tools" =>
            if combinedBuildContent.contains("munit") then "munit+shapeless"
            else if combinedBuildContent.contains("zio-test") then "zio-test"
            else "none"

          case "stainless" =>
            if os.exists(target / "scripts" / "stainless-verify.sh") then "yes"
            else "no"

          case "stryker" =>
            if os.exists(target / "stryker4s.conf") then "yes" else "no"

          case "performance-testing" =>
            if combinedBuildContent.contains("jmh-core") then "yes" else "no"

          case "optics" =>
            if combinedBuildContent.contains("monocle-core") then "yes"
            else "no"

          case "dto-mapping" =>
            if combinedBuildContent.contains("chimney") then "yes" else "no"

          case "api-docs" =>
            if combinedBuildContent.contains("tapir-core") then "yes" else "no"

          case "mcp-tools" =>
            if os.exists(target / ".agents" / "mcp_config.json") || os.exists(
                target / "docs" / "scala-semantic-vs-grep.md"
              )
            then "yes"
            else "no"

          case "mdoc" =>
            if os.exists(target / "mdoc-docs") || os.exists(
                target / "docs" / "index.md"
              )
            then "yes"
            else "no"

          case "git-hooks" =>
            if os.exists(target / ".git" / "hooks" / "pre-commit") || os.exists(
                target / "scripts" / "git-pre-commit.scala"
              )
            then "yes"
            else "no"

          case "version-bump" =>
            if os.exists(target / "scripts" / "version-bump.scala") then "yes"
            else "no"

          case "sdkmanrc" =>
            if os.exists(target / ".sdkmanrc") then "yes" else "no"

          case "scoverage" =>
            if combinedBuildContent.contains("scoverage") then "yes" else "no"

          case "logging" =>
            if combinedBuildContent.contains("logback") || combinedBuildContent
                .contains("log4cats")
            then "yes"
            else "no"

          case "config-loader" =>
            if combinedBuildContent.contains(
                "pureconfig"
              ) || combinedBuildContent.contains("ciris")
            then "yes"
            else "no"

          case "docker" =>
            if os.exists(target / "Dockerfile") then "yes" else "no"

          case _ => f.defaultValue

      f.copy(defaultValue = defaultValue)
    }
