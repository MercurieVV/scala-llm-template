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
