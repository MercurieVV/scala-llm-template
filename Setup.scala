//> using scala 3.3.3
//> using dep com.lihaoyi::os-lib:0.11.8

import scala.io.StdIn.readLine

case class Feature(
    id: String,
    group: String,
    name: String,
    prompt: String,
    defaultValue: String,
    ivyDeps: List[String] = Nil,
    scalacPlugins: List[String] = Nil
)

object Setup:
  val rulesDir = os.home / ".config" / "llm-rules"
  val masterRulesFile = rulesDir / "scala-rules.md"
  val githubRulesUrl =
    "https://raw.githubusercontent.com/MercurieVV/scala-llm-template/master/scala-rules.md"

  var defaultScalaVersion = "3.3.3"

  def getFeaturesList: List[Feature] = List(
    // 1. Language & Compiler Core
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
      "mill"
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
      "no"
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

    // 3. Verification & Quality Assurance
    Feature(
      "test-tools",
      "Quality Assurance",
      "Testing Framework",
      "Test tools (munit+shapeless, zio-test, none)",
      "none"
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
      "no"
    ),
    Feature(
      "performance-testing",
      "Quality Assurance",
      "JMH Performance Testing",
      "Enable JMH performance testing? (yes/no)",
      "no"
    ),

    // 4. Proposed Utilities (Additions)
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
      "api-docs",
      "Ecosystem",
      "Tapir API Documentation",
      "Enable Tapir (declarative endpoints)? (yes/no)",
      "no"
    ),

    // 5. Developer Tooling
    Feature(
      "mcp-tools",
      "Developer Tooling",
      "ScalaSemantic MCP Integration",
      "Enable ScalaSemantic MCP integration (generate rules & configs)? (yes/no)",
      "no"
    ),
    Feature(
      "interaction-hook",
      "Developer Tooling",
      "LLM Interaction Hook",
      "Enable LLM interaction logging script? (yes/no)",
      "no"
    ),
    Feature(
      "mdoc",
      "Developer Tooling",
      "Mdoc Compiler",
      "Enable Mdoc (type-checked documentation)? (yes/no)",
      "no"
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
    )
  )

  def main(args: Array[String]): Unit =
    println(
      "=== Scala Project Setup & Update (Mill/SBT/Scala-CLI + Global Rules) ==="
    )

    // Determine target directory
    val targetDir = args.headOption match
      case Some(".") | None => os.pwd
      case Some(path)       =>
        val d = os.Path(path, os.pwd)
        if !os.exists(d) then os.makeDir.all(d)
        d

    val projectName = targetDir.last
    val buildFile = targetDir / "build.sc"
    val buildSbtFile = targetDir / "build.sbt"
    val projectScalaFile = targetDir / "project.scala"
    val isExisting =
      os.exists(buildFile) || os.exists(buildSbtFile) || os.exists(
        projectScalaFile
      )

    if isExisting then
      println(
        s"Found existing project in $targetDir. Switching to update mode."
      )
    else println(s"Initializing new project in $targetDir...")

    // 1. Resolve latest stable Scala version
    println("Resolving latest stable Scala 3 version from Maven Central...")
    fetchLatestStableVersion("org.scala-lang", "scala3-compiler_3") match
      case Some(ver) =>
        println(s"✓ Found latest stable Scala 3 version: $ver")
        defaultScalaVersion = ver
      case None =>
        println(
          "⚠️ Could not fetch latest Scala version. Using offline fallback: 3.3.3"
        )
        defaultScalaVersion = "3.3.3"

    // 2. Fetch/Update Master Rules in the SHARED folder
    updateMasterRules()

    // 3. Q&A Loop for Features (Grouped output, with detected defaults)
    val featuresToPrompt = detectExistingDefaults(targetDir, getFeaturesList)
    val answers = promptFeaturesGrouped(featuresToPrompt)

    // 4. Setup Project Structure (folders, configs)
    setupStructure(targetDir, answers)

    // 5. Resolve dependencies dynamically once
    val selectedScalaVer =
      answers.getOrElse("scala-version", defaultScalaVersion)
    val (resolvedDeps, resolvedTestDeps, resolvedPlugins) =
      getDependenciesAndPlugins(answers, selectedScalaVer)

    // 6. Create/Update Build Files based on selected Build Tool
    val buildTool = answers.getOrElse("build-tool", "mill").toLowerCase

    if buildTool == "sbt" then
      updateBuildSbt(
        targetDir / "build.sbt",
        projectName,
        selectedScalaVer,
        answers,
        resolvedDeps,
        resolvedTestDeps,
        resolvedPlugins
      )
      val buildSc = targetDir / "build.sc"
      if os.exists(buildSc) then os.remove(buildSc)
    else if buildTool == "scala-cli" then
      updateScalaCli(
        targetDir / "project.scala",
        selectedScalaVer,
        resolvedDeps,
        resolvedTestDeps,
        resolvedPlugins
      )
      val buildSc = targetDir / "build.sc"
      if os.exists(buildSc) then os.remove(buildSc)
      val buildSbt = targetDir / "build.sbt"
      if os.exists(buildSbt) then os.remove(buildSbt)
    else
      // mill
      updateBuildSc(
        buildFile,
        projectName,
        selectedScalaVer,
        answers,
        resolvedDeps,
        resolvedTestDeps,
        resolvedPlugins
      )
      val buildSbt = targetDir / "build.sbt"
      if os.exists(buildSbt) then os.remove(buildSbt)

    // Setup Scala CLI config if selected separately
    val hasScalaCli = answers
      .getOrElse("scripts", "none")
      .toLowerCase == "scala-cli" || buildTool == "scala-cli"
    if hasScalaCli then
      updateScalaCli(
        targetDir / "project.scala",
        selectedScalaVer,
        resolvedDeps,
        resolvedTestDeps,
        resolvedPlugins
      )
    else
      val psc = targetDir / "project.scala"
      if os.exists(psc) then os.remove(psc)

    // Generate and write LLM rules/instructions
    val llmRulesContent = generateLlmRules(answers, selectedScalaVer)

    // 1. Project root rules file
    os.write.over(targetDir / "scala-rules.md", llmRulesContent)
    println("✓ Updated scala-rules.md in project root")

    // 2. Cursor rules file
    os.write.over(targetDir / ".cursorrules", llmRulesContent)
    println("✓ Updated .cursorrules in project root")

    // 3. Workspace agent rules file
    val agentsDir = targetDir / ".agents"
    os.makeDir.all(agentsDir)
    os.write.over(agentsDir / "AGENTS.md", llmRulesContent)
    println("✓ Updated .agents/AGENTS.md")

    // 4. Update CLAUDE.md and CONVENTIONS.md
    updateGuideFile(targetDir / "CLAUDE.md", answers)
    updateGuideFile(targetDir / "CONVENTIONS.md", answers)

    // 7. Setup Git (Stage changes)
    setupGit(targetDir)

    println(s"\n=== Setup Completed Successfully! ===")
    println(s"Project Location: $targetDir")
    println(s"Selected Scala Version: $selectedScalaVer")
    println(s"Build Tool Configured: ${buildTool.toUpperCase}")
    println("\nRules have been configured locally in the project folder:")
    println(s"  - scala-rules.md (generic)")
    println(s"  - .cursorrules (Cursor)")
    println(s"  - .agents/AGENTS.md (Antigravity/Gemini)")

    val hasInteractionHook =
      answers.getOrElse("interaction-hook", "no").toLowerCase.startsWith("y")
    if hasInteractionHook then
      println(
        "\nTo activate the LLM interaction logging hook, add the following to ~/.claude/settings.json:"
      )
      println(
        """{
          |  "hooks": {
          |    "PostToolUse": [{
          |      "matcher": "Read|Edit|Write|MultiEdit|Grep|Glob|Bash",
          |      "hooks": [{ "type": "command", "command": "scala-cli run \"$CLAUDE_PROJECT_DIR/scripts/log-scala-interaction.scala\" --" }]
          |    }]
          |  }
          |}""".stripMargin
      )

    if buildTool == "sbt" then
      println("\nRun 'sbt test' to verify and compile.")
    else if buildTool == "scala-cli" then
      println("\nRun 'scala-cli test .' to verify and compile.")
    else println("\nRun 'mill app.test' to verify and compile.")

  def updateMasterRules(): Unit =
    if !os.exists(rulesDir) then os.makeDir.all(rulesDir)
    println(s"Synchronizing shared master rules at $masterRulesFile...")
    try
      val content = clippyFetch(githubRulesUrl)
      os.write.over(masterRulesFile, content)
      println("✓ Rules synchronized from GitHub.")
    catch
      case _: Exception =>
        println(
          "⚠️ Could not fetch rules from GitHub. Using/creating local cache."
        )
        if !os.exists(masterRulesFile) then
          val defaultRules = """# Scala 3 LLM Guidelines & Coding Rules
                                |
                                |You are acting as an expert Scala engineer. When writing, refactoring, or reviewing Scala code in this codebase, you must follow these rules strictly:
                                |
                                |## 1. Syntax & Style (Scala 3)
                                |* Use the new Scala 3 optional braces syntax (significant indentation).
                                |* Do not write curly braces `{}` for packages, classes, methods, or control flow unless necessary.
                                |* Indentation size: 2 spaces.
                                |* Avoid using semicolons.
                                |
                                |## 2. Functional Programming Standards
                                |* **Immutability First**: Use `val` for all variables. Do not use `var` unless absolutely required for performance in a local loop.
                                |* **Immutable Collections**: Always use standard immutable collections (`List`, `Vector`, `Map`, `Set`).
                                |* **No Nulls**: Do not return `null` or use `Option.get`. Always handle optionals safely using pattern matching.
                                |* **Error Handling**: Do not throw custom exceptions. Instead, return failures explicitly using `Either` or `Try`.
                                |""".stripMargin
          os.write(masterRulesFile, defaultRules)
          println("✓ Initialized fallback master rules locally.")

  def clippyFetch(url: String): String =
    val p = os
      .proc("curl", "-fsSL", "--connect-timeout", "3", url)
      .call(stderr = os.Pipe)
    if p.exitCode == 0 then p.out.text()
    else throw new RuntimeException("Fetch failed")

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
      features: List[Feature]
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
      val detectedDefault = f.id match
        // 1. Build Tool
        case "build-tool" =>
          if os.exists(buildScFile) then "mill"
          else if os.exists(buildSbtFile) then "sbt"
          else if os.exists(projectScalaFile) then "scala-cli"
          else "mill"

        // 2. Scala Version
        case "scala-version" =>
          val scalaVerRegex =
            """(?:def\s+scalaVersion\s*=\s*"|scalaVersion\s*:=\s*")([^"]+)"""".r
          scalaVerRegex.findFirstMatchIn(combinedBuildContent) match
            case Some(m) => m.group(1)
            case None    => f.defaultValue

        // 3. Cross Version Compilation
        case "cross-version" =>
          val hasCross = combinedBuildContent.contains("CrossScalaModule") ||
            combinedBuildContent.contains("crossScalaVersions") ||
            combinedBuildContent.contains("Cross[AppModule]")
          if hasCross then "yes" else "no"

        // 4. Scripting Tool
        case "scripts" =>
          if os.exists(projectScalaFile) && !os.exists(buildScFile) && !os
              .exists(buildSbtFile)
          then
            // If it's scala-cli build tool, scripts is none
            "none"
          else if os.exists(projectScalaFile) then "scala-cli"
          else "none"

        // 5. GitHub Flow
        case "github-flow" =>
          if os.exists(target / ".github" / "workflows" / "ci.yml") then "yes"
          else "no"

        // 6. Ecosystem
        case "ecosystem" =>
          if combinedBuildContent.contains("cats-core") then "typelevel"
          else if combinedBuildContent.contains("zio") then "zio"
          else "none"

        // 7. Web Server
        case "web-server" =>
          val hasWebServer =
            combinedBuildContent.contains("http4s-ember-server") ||
              combinedBuildContent.contains("zio-http")
          if hasWebServer then "yes" else "no"

        // 8. Web Client
        case "web-client" =>
          val hasWebClient =
            combinedBuildContent.contains("http4s-ember-client") ||
              combinedBuildContent.contains("sttp.client")
          if hasWebClient then "yes" else "no"

        // 9. Database Access
        case "db-access" =>
          val hasDb = combinedBuildContent.contains("doobie") ||
            combinedBuildContent.contains("quill-jdbc") ||
            combinedBuildContent.contains("postgresql")
          if hasDb then "yes" else "no"

        // 10. Serverless
        case "serverless-run" =>
          if combinedBuildContent.contains("aws-lambda-java-core") then "yes"
          else "no"

        // 11. Testing Framework
        case "test-tools" =>
          if combinedBuildContent.contains("munit") then "munit+shapeless"
          else if combinedBuildContent.contains("zio-test") then "zio-test"
          else "none"

        // 12. Stainless
        case "stainless" =>
          if combinedBuildContent.contains("stainless-compiler-plugin") then
            "yes"
          else "no"

        // 13. Stryker
        case "stryker" =>
          if os.exists(target / "stryker4s.conf") then "yes" else "no"

        // 14. JMH Performance Testing
        case "performance-testing" =>
          if combinedBuildContent.contains("jmh-core") then "yes" else "no"

        // 17. Optics (Monocle)
        case "optics" =>
          if combinedBuildContent.contains("monocle-core") then "yes" else "no"

        // 18. DTO Mapping (Chimney)
        case "dto-mapping" =>
          if combinedBuildContent.contains("chimney") then "yes" else "no"

        // 19. API Docs (Tapir)
        case "api-docs" =>
          if combinedBuildContent.contains("tapir-core") then "yes" else "no"

        // 20. ScalaSemantic MCP
        case "mcp-tools" =>
          if os.exists(target / ".agents" / "mcp_config.json") || os.exists(
              target / "docs" / "scala-semantic-vs-grep.md"
            )
          then "yes"
          else "no"

        // 21. LLM Interaction Hook
        case "interaction-hook" =>
          if os.exists(target / "scripts" / "log-scala-interaction.scala") || os
              .exists(target / "scripts" / "log-scala-interaction.py")
          then "yes"
          else "no"

        // 22. Mdoc Compiler
        case "mdoc" =>
          if os.exists(target / "mdoc-docs") || os.exists(
              target / "docs" / "index.md"
            )
          then "yes"
          else "no"

        // 23. Git Hooks
        case "git-hooks" =>
          if os.exists(target / ".git" / "hooks" / "pre-commit") || os.exists(
              target / "scripts" / "git-pre-commit.scala"
            )
          then "yes"
          else "no"

        // 24. Version Bumping
        case "version-bump" =>
          if os.exists(target / "scripts" / "version-bump.scala") then "yes"
          else "no"

        case _ => f.defaultValue

      f.copy(defaultValue = detectedDefault)
    }

  def fetchLatestStableVersion(
      group: String,
      artifact: String
  ): Option[String] =
    val groupPath = group.replace('.', '/')
    val url =
      s"https://repo1.maven.org/maven2/$groupPath/$artifact/maven-metadata.xml"
    try
      val xml = clippyFetch(url)
      val versionRegex = """<version>([^<]+)</version>""".r
      val versions = versionRegex.findAllMatchIn(xml).map(_.group(1)).toList
      val stableVersions = versions.filter { v =>
        v.matches("^[0-9]+(\\.[0-9]+)*$")
      }
      if stableVersions.nonEmpty then Some(stableVersions.last)
      else
        val ReleaseRegex = """<release>([^<]+)</release>""".r
        val LatestRegex = """<latest>([^<]+)</latest>""".r
        ReleaseRegex
          .findFirstMatchIn(xml)
          .map(_.group(1))
          .orElse(LatestRegex.findFirstMatchIn(xml).map(_.group(1)))
    catch case _: Exception => None

  def resolveLatestVersion(dep: String, scalaVer: String): String =
    val isScalaDep = dep.contains("::")
    val parts = if isScalaDep then dep.split("::") else dep.split(":")
    if parts.length >= 2 then
      val group = parts(0)
      val rest = parts(1).split(":")
      val artifactName = rest(0).stripPrefix(":")
      val defaultVer = if rest.length > 1 then rest.last else "latest"

      val scalaSuffix =
        if isScalaDep then if scalaVer.startsWith("3") then "_3" else "_2.13"
        else ""

      val fullArtifact = s"$artifactName$scalaSuffix"

      print(s"Resolving latest version for $group:$fullArtifact... ")
      fetchLatestStableVersion(group, fullArtifact) match
        case Some(latestVer) =>
          println(s"✓ $latestVer")
          val sep = if isScalaDep then "::" else ":"
          s"$group$sep$artifactName:$latestVer"
        case None =>
          println(s"⚠️ Failed. Using default: $defaultVer")
          dep
    else dep

  // Retrieve dependencies and plugins based on choices
  def getDependenciesAndPlugins(
      answers: Map[String, String],
      scalaVer: String
  ): (List[String], List[String], List[String]) =
    var deps = List.empty[String]
    var testDeps = List.empty[String]
    var plugins = List.empty[String]

    val eco = answers.getOrElse("ecosystem", "typelevel").toLowerCase
    val isZIO = eco == "zio"
    val isTypelevel = eco == "typelevel"

    // 1. Ecosystem
    if isTypelevel then
      deps = deps :+ "org.typelevel::cats-core:2.10.0"
      deps = deps :+ "org.typelevel::cats-effect:3.5.4"
    else if isZIO then
      deps = deps :+ "dev.zio::zio:2.0.21"
      deps = deps :+ "dev.zio::zio-streams:2.0.21"

    // 2. Web Server
    val hasWebServer =
      answers.getOrElse("web-server", "no").toLowerCase.startsWith("y")
    if hasWebServer then
      if isTypelevel then
        deps = deps :+ "org.http4s::http4s-ember-server:0.23.27"
        deps = deps :+ "org.http4s::http4s-dsl:0.23.27"
      else if isZIO then deps = deps :+ "dev.zio::zio-http:3.0.0-RC6"

    // 3. Web Client
    val hasWebClient =
      answers.getOrElse("web-client", "no").toLowerCase.startsWith("y")
    if hasWebClient then
      if isTypelevel then
        deps = deps :+ "org.http4s::http4s-ember-client:0.23.27"
      else if isZIO then
        deps = deps :+ "com.softwaremill.sttp.client4::zio:4.0.0-RC1"
      else deps = deps :+ "com.softwaremill.sttp.client4::core:4.0.0-RC1"

    // 4. Database Access
    val hasDb = answers.getOrElse("db-access", "no").toLowerCase.startsWith("y")
    if hasDb then
      if isTypelevel then
        deps = deps :+ "org.tpolecat::doobie-core:1.0.0-RC5"
        deps = deps :+ "org.tpolecat::doobie-hikari:1.0.0-RC5"
      else if isZIO then deps = deps :+ "io.getquill::quill-jdbc-zio:4.8.4"
      else deps = deps :+ "org.postgresql:postgresql:42.7.3"

    // 5. Serverless Deployment
    val hasServerless =
      answers.getOrElse("serverless-run", "no").toLowerCase.startsWith("y")
    if hasServerless then
      deps = deps :+ "com.amazonaws:aws-lambda-java-core:1.2.3"
      deps = deps :+ "com.amazonaws:aws-lambda-java-events:3.11.4"

    // 6. Testing Framework
    val testTools =
      answers.getOrElse("test-tools", "munit+shapeless").toLowerCase
    if testTools.contains("munit") then
      testDeps = testDeps :+ "org.scalameta::munit:1.0.0"
    if testTools.contains("shapeless") then
      testDeps = testDeps :+ "org.typelevel::shapeless3-deriving:3.3.0"
    if isZIO || testTools.contains("zio") then
      testDeps = testDeps :+ "dev.zio::zio-test:2.0.21"
      testDeps = testDeps :+ "dev.zio::zio-test-sbt:2.0.21"

    // 7. Stainless Formal Verification
    val hasStainless =
      answers.getOrElse("stainless", "no").toLowerCase.startsWith("y")
    if hasStainless then
      plugins = plugins :+ "ch.epfl.lara::stainless-compiler-plugin:0.9.8.1"

    // 8. JMH Performance Testing
    val hasJmh =
      answers.getOrElse("performance-testing", "no").toLowerCase.startsWith("y")
    if hasJmh then deps = deps :+ "org.openjdk.jmh:jmh-core:1.37"

    // 9. Optics (Monocle)
    val hasOptics =
      answers.getOrElse("optics", "no").toLowerCase.startsWith("y")
    if hasOptics then deps = deps :+ "dev.optics::monocle-core:3.2.0"

    // 10. DTO Mapping (Chimney)
    val hasDto =
      answers.getOrElse("dto-mapping", "no").toLowerCase.startsWith("y")
    if hasDto then deps = deps :+ "io.scalaland::chimney:0.8.5"

    // 11. API Docs (Tapir)
    val hasApiDocs =
      answers.getOrElse("api-docs", "no").toLowerCase.startsWith("y")
    if hasApiDocs then
      deps = deps :+ "com.softwaremill.sttp.tapir::tapir-core:1.10.0"

    // Always add Wartremover compiler plugin for non-SBT builds (Mill, Scala CLI)
    val buildTool = answers.getOrElse("build-tool", "mill").toLowerCase
    val finalPlugins =
      if buildTool != "sbt" then plugins :+ "org.wartremover::wartremover:3.2.5"
      else plugins

    println("\nResolving latest library versions from Maven Central...")
    val resolvedDeps = deps.map(dep => resolveLatestVersion(dep, scalaVer))
    val resolvedTestDeps =
      testDeps.map(dep => resolveLatestVersion(dep, scalaVer))
    val resolvedPlugins =
      finalPlugins.map(plugin => resolveLatestVersion(plugin, scalaVer))

    (resolvedDeps, resolvedTestDeps, resolvedPlugins)

  def setupStructure(target: os.Path, answers: Map[String, String]): Unit =
    os.makeDir.all(target / "app" / "src")
    os.makeDir.all(target / "app" / "test" / "src")

    // Write .gitignore if missing
    val gitignore = target / ".gitignore"
    if !os.exists(gitignore) then
      os.write(
        gitignore,
        "out/\n.bsp/\n.metals/\n.vscode/\n.idea/\n.DS_Store\n"
      )

    // Write/Remove .scalafmt.conf
    // Write .scalafmt.conf (always enabled)
    val scalafmt = target / ".scalafmt.conf"
    if !os.exists(scalafmt) then
      os.write(scalafmt, "version = \"3.8.1\"\nrunner.dialect = scala3\n")
      println("✓ Created Scalafmt configuration (.scalafmt.conf)")

    // Write/Remove Stryker4s config
    val strykerConf = target / "stryker4s.conf"
    if answers.getOrElse("stryker", "no").toLowerCase == "yes" then
      if !os.exists(strykerConf) then
        val strykerContent =
          """stryker4s {
            |  mutate: [ "app/src/**/*.scala" ]
            |  reporters: ["html", "json"]
            |  thresholds {
            |    high = 80
            |    low = 60
            |    break = 0
            |  }
            |  debug {
            |    log-test-runner-stdout = true
            |  }
            |}
            |""".stripMargin
        os.write(strykerConf, strykerContent)
        println("✓ Created Stryker4s configuration (stryker4s.conf)")
    else if os.exists(strykerConf) then
      os.remove(strykerConf)
      println("✓ Removed Stryker4s configuration (stryker4s.conf)")

    // Write .scalafix.conf (always enabled)
    val scalafixConf = target / ".scalafix.conf"
    if !os.exists(scalafixConf) then
      os.write(
        scalafixConf,
        """rules = [
                               |  OrganizeImports,
                               |  DisableSyntax,
                               |  LeakingImplicitClassVal,
                               |  NoValInForComprehension
                               |]
                               |""".stripMargin
      )
      println("✓ Created Scalafix configuration (.scalafix.conf)")

    // Setup/Remove GitHub Flow CI Workflow
    val workflowDir = target / ".github" / "workflows"
    val ciFile = workflowDir / "ci.yml"
    if answers.getOrElse("github-flow", "no").toLowerCase == "yes" then
      os.makeDir.all(workflowDir)
      if !os.exists(ciFile) then
        val buildTool = answers.getOrElse("build-tool", "mill").toLowerCase
        val testCmd =
          if buildTool == "sbt" then "sbt test"
          else if buildTool == "scala-cli" then "scala-cli test ."
          else "mill app.test"
        val ciContent = s"""name: CI
                           |on:
                           |  push:
                           |    branches: [ main, master ]
                           |  pull_request:
                           |    branches: [ main, master ]
                           |jobs:
                           |  build:
                           |    runs-on: ubuntu-latest
                           |    steps:
                           |    - uses: actions/checkout@v4
                           |    - name: Set up JDK
                           |      uses: actions/setup-java@v4
                           |      with:
                           |        distribution: 'temurin'
                           |        java-version: '17'
                           |    - name: Run tests
                           |      run: $testCmd
                           |""".stripMargin
        os.write(ciFile, ciContent)
        println("✓ Created GitHub CI workflow (.github/workflows/ci.yml)")
    else
      if os.exists(ciFile) then
        os.remove(ciFile)
        println("✓ Removed GitHub CI workflow (.github/workflows/ci.yml)")
      if os.exists(workflowDir) && os.list(workflowDir).isEmpty then
        os.remove(workflowDir)
      val githubDir = target / ".github"
      if os.exists(githubDir) && os.list(githubDir).isEmpty then
        os.remove(githubDir)

    // Write project-local .agents/mcp_config.json if MCP tools are enabled OR launcher script exists
    val hasMcpOption =
      answers.getOrElse("mcp-tools", "no").toLowerCase.startsWith("y")
    val localLauncher = os.home / ".local" / "bin" / "scalasemantic-mcp.sh"
    val localLauncherExists = os.exists(localLauncher)

    val agentsDir = target / ".agents"
    val mcpConfig = agentsDir / "mcp_config.json"

    if hasMcpOption || localLauncherExists then
      val launcherPath =
        if localLauncherExists then localLauncher.toString
        else "scalasemantic-mcp"
      os.makeDir.all(agentsDir)
      val configContent =
        s"""{
           |  "mcpServers": {
           |    "scala-semantic": {
           |      "command": "$launcherPath",
           |      "args": ["${target.toString}"]
           |    }
           |  }
           |}
           |""".stripMargin
      os.write.over(mcpConfig, configContent)
      println(
        "✓ Configured local scala-semantic MCP server (.agents/mcp_config.json)"
      )
    else if os.exists(mcpConfig) then
      os.remove(mcpConfig)
      println(
        "✓ Removed local scala-semantic MCP server configuration (.agents/mcp_config.json)"
      )

    // Write docs/scala-semantic-vs-grep.md if ScalaSemantic MCP is enabled
    val docsDir = target / "docs"
    val vsGrepDoc = docsDir / "scala-semantic-vs-grep.md"
    if hasMcpOption then
      os.makeDir.all(docsDir)
      val vsGrepContent =
        """# ScalaSemantic vs `grep`
          |
          |`grep` is the tool an agent reaches for by default. ScalaSemantic is the semantic complement — not a replacement. This page covers where each wins and the measured cost difference.
          |
          |## What ScalaSemantic does better
          |
          |- **Exact symbols, no false hits.** `find_usages` on `pkg/Foo#bar().` returns *that* method — not every `bar` in the repo, not a `bar` in a comment, not an unrelated overload.
          |- **No false negatives from naming.** Import aliases, backtick names, and shadowing all resolve to the same symbol; grep misses renamed-on-import references.
          |- **Relationships grep cannot express.** Subtypes across the whole index (`class_hierarchy`), which givens produce a type (`resolve_implicits`), the shortest call path between two methods (`call_path`), declared-vs-inherited members. These are graph queries over the compiled program.
          |- **Type-aware signatures.** `method_signature` renders type params and `implicit`/`using` parameter lists — information not in the source in a greppable form.
          |
          |## What `grep` does better
          |
          |- **Zero setup, instant.** No compile, no SemanticDB, no JVM server. Works on a fresh checkout.
          |- **Works on any text.** Comments, string literals, TODOs, build files, YAML, other languages.
          |- **Always current.** Matches bytes on disk right now; SemanticDB only sees what the last `compile` emitted.
          |- **Tolerates broken code.** Finds text in code that doesn't compile.
          |
          |## Rule of thumb
          |
          || Question | Reach for |
          ||---|---|
          || Where does this string / comment / TODO appear? | `grep` |
          || Something in a config or non-Scala file | `grep` |
          || Code doesn't compile yet | `grep` |
          || Every caller of *this exact* method | `find_usages` |
          || Who extends this trait? / which givens produce `T`? | `class_hierarchy` / `resolve_implicits` |
          || Path from method `a` to method `c` | `call_path` |
          |
          |## Token & context cost (measured)
          |
          |Question: *"where is `SemanticIndex#displayName` used?"*
          |
          || | `find_usages` | `grep "displayName"` |
          ||---|---|---|
          || Hits returned | **16** (1 def + 15 refs, all correct) | **87** matches |
          || Right symbol | 16 / 16 | ~16 / 87 — the other ~71 are a different `displayName` |
          || Output size | **1,630 bytes** | **12,645 bytes** |
          || Approx tokens (÷4) | **~407** | **~3,161** |
          || Ratio | 1× | **~7.8×** |
          |
          |The ~8× context bloat is only the first request. Grep's bloat compounds: the wrong hits require opening files to disambiguate, and the large result re-enters the conversation as input tokens on every turn. The semantic result is small, exact, and stays small across the whole conversation.
          |
          |## Limitations
          |
          |- **Index freshness.** Results reflect the last `compile`. Recompile to see new code; restart the MCP session to reload the index.
          |- **Compiled Scala only.** No comments, strings, generated-but-not-compiled code, or non-Scala files.
          |""".stripMargin
      os.write.over(vsGrepDoc, vsGrepContent)
      println(
        "✓ Created ScalaSemantic vs grep documentation (docs/scala-semantic-vs-grep.md)"
      )
    else
      if os.exists(vsGrepDoc) then
        os.remove(vsGrepDoc)
        println("✓ Removed ScalaSemantic vs grep documentation")
      if os.exists(docsDir) && os.list(docsDir).isEmpty then os.remove(docsDir)

    // Write scripts/worktree-start.scala and scripts/worktree-finish.scala (always enabled)
    val scriptsDir = target / "scripts"
    os.makeDir.all(scriptsDir)

    // Clean up old bash scripts if they exist
    val oldStart = scriptsDir / "worktree-start.sh"
    if os.exists(oldStart) then os.remove(oldStart)
    val oldFinish = scriptsDir / "worktree-finish.sh"
    if os.exists(oldFinish) then os.remove(oldFinish)

    val wtStartScript = scriptsDir / "worktree-start.scala"
    val wtStartContent =
      """#!/usr/bin/env scala-cli
        |
        |//> using scala 3.3.4
        |//> using dep com.lihaoyi::os-lib:0.11.8
        |
        |import os._
        |
        |object WorktreeStart:
        |  def main(args: Array[String]): Unit =
        |    if args.isEmpty then
        |      println("Error: task branch name required")
        |      sys.exit(1)
        |
        |    val branch = args.head
        |    val repoRoot = os.Path(os.proc("git", "rev-parse", "--show-toplevel").call().out.text().trim)
        |    
        |    // Detect default branch
        |    val base = try {
        |      val raw = os.proc("git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD").call(cwd = repoRoot).out.text().trim
        |      raw.stripPrefix("origin/")
        |    } catch {
        |      case _: Exception => "main"
        |    }
        |
        |    val finalBase = if os.proc("git", "show-ref", "--verify", "--quiet", s"refs/heads/$base").call(cwd = repoRoot, check = false).exitCode == 0 then
        |      base
        |    else if os.proc("git", "show-ref", "--verify", "--quiet", "refs/heads/master").call(cwd = repoRoot, check = false).exitCode == 0 then
        |      "master"
        |    else
        |      "main"
        |
        |    val wt = repoRoot / ".worktrees" / branch
        |
        |    if os.exists(wt) then
        |      println(s"Error: Worktree directory already exists: $wt")
        |      sys.exit(1)
        |
        |    println("Fetching latest changes from origin...")
        |    try {
        |      os.proc("git", "fetch", "origin", finalBase, "--quiet").call(cwd = repoRoot)
        |    } catch {
        |      case _: Exception => // ignore fetch failures
        |    }
        |
        |    println(s"Creating branch '$branch' off '$finalBase'...")
        |    // Try creating local branch off origin/base first
        |    val branchCreated = os.proc("git", "branch", branch, s"origin/$finalBase").call(cwd = repoRoot, check = false).exitCode == 0 ||
        |                        os.proc("git", "branch", branch, finalBase).call(cwd = repoRoot, check = false).exitCode == 0
        |
        |    println(s"Adding git worktree at '$wt'...")
        |    val wtAdded = os.proc("git", "worktree", "add", "-b", branch, wt.toString, finalBase).call(cwd = repoRoot, check = false).exitCode == 0 ||
        |                  os.proc("git", "worktree", "add", wt.toString, branch).call(cwd = repoRoot, check = false).exitCode == 0
        |
        |    if !wtAdded then
        |      println("Error: Failed to add git worktree")
        |      sys.exit(1)
        |
        |    // Copy untracked config/rules files
        |    println("Syncing workspace rules and config files to worktree...")
        |    os.makeDir.all(wt / ".agents")
        |    val filesToCopy = Seq(
        |      Path(".agents/mcp_config.json", repoRoot),
        |      Path(".agents/AGENTS.md", repoRoot),
        |      Path(".cursorrules", repoRoot),
        |      Path("scala-rules.md", repoRoot)
        |    )
        |
        |    for f <- filesToCopy if os.exists(f) do
        |      val relative = f.relativeTo(repoRoot)
        |      val dest = wt / relative
        |      os.makeDir.all(dest / os.up)
        |      os.copy.over(f, dest)
        |
        |    println("========================================================================")
        |    println("Worktree created successfully!")
        |    println(s"  Path: $wt")
        |    println(s"  Branch: $branch")
        |    println("")
        |    println("To switch to your new worktree, run:")
        |    println(s"  cd $wt")
        |    println("========================================================================")
        |""".stripMargin
    os.write.over(wtStartScript, wtStartContent)
    try { os.perms.set(wtStartScript, "rwxr-xr-x") }
    catch { case _: Exception => }
    println("✓ Created worktree start script (scripts/worktree-start.scala)")

    val wtFinishScript = scriptsDir / "worktree-finish.scala"
    val wtFinishContent =
      """#!/usr/bin/env scala-cli
        |
        |//> using scala 3.3.4
        |//> using dep com.lihaoyi::os-lib:0.11.8
        |
        |import os._
        |
        |object WorktreeFinish:
        |  def main(args: Array[String]): Unit =
        |    val currentDir = os.pwd
        |    val repoRoot = try {
        |      os.Path(os.proc("git", "rev-parse", "--show-toplevel").call().out.text().trim)
        |    } catch {
        |      case _: Exception =>
        |        println("Error: Not inside a git repository")
        |        sys.exit(1)
        |    }
        |
        |    var branch = ""
        |    var wtDir: os.Path = os.Path("/")
        |    var mainRepo: os.Path = os.Path("/")
        |    val wtPattern = "\\\\.worktrees/([^/]+)".r
        |
        |    val currentDirStr = currentDir.toString
        |    wtPattern.findFirstMatchIn(currentDirStr) match
        |      case Some(m) =>
        |        branch = m.group(1)
        |        wtDir = repoRoot
        |        val idx = currentDirStr.indexOf("/.worktrees/")
        |        mainRepo = os.Path(currentDirStr.substring(0, idx))
        |      case None =>
        |        if args.isEmpty then
        |          println("Error: Not in a worktree. Please provide the branch name as an argument.")
        |          sys.exit(1)
        |        branch = args.head
        |        mainRepo = repoRoot
        |        wtDir = mainRepo / ".worktrees" / branch
        |
        |    if !os.exists(wtDir) then
        |      println(s"Error: Worktree directory not found at $wtDir")
        |      sys.exit(1)
        |
        |    val message = if args.length > 1 then args(1) else s"$branch: automated implementation"
        |
        |    // Check for changes in worktree
        |    val isClean = os.proc("git", "status", "--porcelain").call(cwd = wtDir).out.text().trim.isEmpty
        |    if !isClean then
        |      println("Committing changes in worktree...")
        |      os.proc("git", "add", ".").call(cwd = wtDir)
        |      os.proc("git", "commit", "-m", message).call(cwd = wtDir)
        |
        |    // Detect default branch
        |    val base = try {
        |      val raw = os.proc("git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD").call(cwd = mainRepo).out.text().trim
        |      raw.stripPrefix("origin/")
        |    } catch {
        |      case _: Exception => "main"
        |    }
        |
        |    val finalBase = if os.proc("git", "show-ref", "--verify", "--quiet", s"refs/heads/$base").call(cwd = mainRepo, check = false).exitCode == 0 then
        |      base
        |    else if os.proc("git", "show-ref", "--verify", "--quiet", "refs/heads/master").call(cwd = mainRepo, check = false).exitCode == 0 then
        |      "master"
        |    else
        |      "main"
        |
        |    println(s"Merging branch '$branch' into '$finalBase'...")
        |    os.proc("git", "checkout", finalBase).call(cwd = mainRepo)
        |    os.proc("git", "merge", branch, "--no-ff", "-m", s"Merge branch '$branch' into $finalBase").call(cwd = mainRepo)
        |
        |    println(s"Removing worktree at '$wtDir'...")
        |    try {
        |      os.proc("git", "worktree", "remove", "--force", wtDir.toString).call(cwd = mainRepo)
        |    } catch {
        |      case _: Exception => // ignore if already gone
        |    }
        |
        |    println(s"Deleting branch '$branch'...")
        |    val branchDeleted = os.proc("git", "branch", "-d", branch).call(cwd = mainRepo, check = false).exitCode == 0 ||
        |                        os.proc("git", "branch", "-D", branch).call(cwd = mainRepo, check = false).exitCode == 0
        |
        |    println("========================================================================")
        |    println("Worktree cleaned up successfully!")
        |    println(s"  Merged branch: $branch into $finalBase")
        |    println(s"  Returned to: $mainRepo (branch: $finalBase)")
        |    println("")
        |    println("To return your shell to the main repository, run:")
        |    println(s"  cd $mainRepo")
        |    println("========================================================================")
        |""".stripMargin
    os.write.over(wtFinishScript, wtFinishContent)
    try { os.perms.set(wtFinishScript, "rwxr-xr-x") }
    catch { case _: Exception => }
    println("✓ Created worktree finish script (scripts/worktree-finish.scala)")

    // Write scripts/log-scala-interaction.scala if the interaction-hook is enabled
    val hasInteractionHook =
      answers.getOrElse("interaction-hook", "no").toLowerCase.startsWith("y")
    val oldLogScript = scriptsDir / "log-scala-interaction.py"
    if os.exists(oldLogScript) then os.remove(oldLogScript)

    val logScript = scriptsDir / "log-scala-interaction.scala"
    if hasInteractionHook then
      val scriptContent =
        s"""#!/usr/bin/env scala-cli
           |
           |//> using scala 3.3.4
           |//> using dep com.lihaoyi::upickle:4.4.3
           |//> using dep com.lihaoyi::os-lib:0.11.8
           |
           |import java.io.BufferedReader
           |import java.io.InputStreamReader
           |import java.time.LocalDateTime
           |import java.time.format.DateTimeFormatter
           |import ujson.Value
           |
           |object LogScalaInteraction:
           |  def main(args: Array[String]): Unit =
           |    try {
           |      val reader = new BufferedReader(new InputStreamReader(System.in))
           |      val sb = new StringBuilder()
           |      var line = reader.readLine()
           |      while line != null do
           |        sb.append(line)
           |        line = reader.readLine()
           |
           |      val jsonStr = sb.toString()
           |      if jsonStr.trim.isEmpty then sys.exit(0)
           |
           |      val data = ujson.read(jsonStr)
           |      val tool = data.obj.get("tool_name").flatMap(_.strOpt).getOrElse("")
           |      val inp = data.obj.get("tool_input").map(_.obj).getOrElse(Map.empty[String, Value])
           |      val cwd = data.obj.get("cwd").flatMap(_.strOpt).getOrElse("")
           |
           |      def checkTarget(): Option[String] =
           |        tool match
           |          case "Read" | "Edit" | "Write" | "MultiEdit" | "NotebookEdit" =>
           |            inp.get("file_path").flatMap { v =>
           |              v.strOpt.flatMap { str =>
           |                if str.endsWith(".scala") then Some(str) else None
           |              }
           |            }
           |          case "Grep" | "Glob" =>
           |            val pattern = inp.get("pattern").map(_.toString).getOrElse("")
           |            val glob = inp.get("glob").map(_.toString).getOrElse("")
           |            val path = inp.get("path").map(_.toString).getOrElse("")
           |            val combined = s"$$pattern $$glob $$path"
           |            if combined.toLowerCase.contains("scala") then Some(combined.trim) else None
           |          case "Bash" =>
           |            inp.get("command").flatMap { v =>
           |              v.strOpt.flatMap { str =>
           |                if str.contains(".scala") then Some(str) else None
           |              }
           |            }
           |          case _ => None
           |
           |      checkTarget() match
           |        case Some(target) =>
           |          val op = tool match
           |            case "Read" => "read"
           |            case "Grep" | "Glob" => "search"
           |            case "Bash" => "bash"
           |            case _ => "write"
           |
           |          val ts = LocalDateTime.now().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME)
           |          val record = ujson.Obj(
           |            "ts" -> ts,
           |            "tool" -> tool,
           |            "op" -> op,
           |            "target" -> target.take(500),
           |            "cwd" -> cwd
           |          )
           |
           |          val logPathStr = System.getenv().getOrDefault(
           |            "SCALA_INTERACTION_LOG",
           |            s"$${System.getProperty("user.home")}/.claude/scala-interactions.jsonl"
           |          )
           |          val logPath = os.Path(logPathStr)
           |          os.makeDir.all(logPath / os.up)
           |          os.write.append(logPath, record.render() + "\\n")
           |        case None => ()
           |    } catch {
           |      case _: Exception => ()
           |    }
           |    sys.exit(0)
           |""".stripMargin
      os.write.over(logScript, scriptContent)
      try {
        os.perms.set(logScript, "rwxr-xr-x")
      } catch {
        case _: Exception => // ignore Windows
      }
      println(
        "✓ Created LLM interaction logging script (scripts/log-scala-interaction.scala)"
      )
    else if os.exists(logScript) then
      os.remove(logScript)
      println("✓ Removed LLM interaction logging script")

    // Setup / Remove Mdoc documentation features
    val hasMdoc = answers.getOrElse("mdoc", "no").toLowerCase.startsWith("y")
    val mdocDocsDir = target / "mdoc-docs"
    val docsSrcDir = mdocDocsDir / "src" / "main" / "scala"

    if hasMdoc then
      // 1. Create docs/index.md if missing
      os.makeDir.all(docsDir)
      val docIndex = docsDir / "index.md"
      if !os.exists(docIndex) then
        os.write(
          docIndex,
          """# Welcome to the Project Documentation
            |
            |This documentation is compiled and type-checked using **mdoc**.
            |
            |## Scala 3 Code Example
            |
            |```scala mdoc
            |val message = "Hello from Scala 3 type-checked docs!"
            |println(message)
            |```
            |""".stripMargin
        )
        println("✓ Created initial documentation file (docs/index.md)")

      // 2. Create mdoc-docs/src/main/scala/DocsMain.scala
      os.makeDir.all(docsSrcDir)
      val docsMainFile = docsSrcDir / "DocsMain.scala"
      val docsMainContent =
        """//> using scala 3.3.4
          |//> using dep org.scalameta::mdoc:2.9.0
          |
          |package docs
          |
          |import java.nio.file.Paths
          |
          |object DocsMain:
          |  def main(args: Array[String]): Unit =
          |    val settings = mdoc
          |      .MainSettings()
          |      .withIn(Paths.get("docs"))
          |      .withOut(Paths.get("website", "docs"))
          |      .withClasspath(System.getProperty("java.class.path"))
          |      .withArgs(args.toList)
          |    val exitCode = mdoc.Main.process(settings)
          |    if exitCode != 0 then sys.exit(exitCode)
          |""".stripMargin
      os.write.over(docsMainFile, docsMainContent)
      println(
        "✓ Created mdoc documentation runner (mdoc-docs/src/main/scala/DocsMain.scala)"
      )
    else
      // Cleanup if mdoc is disabled
      val docsMainFile = docsSrcDir / "DocsMain.scala"
      if os.exists(docsMainFile) then
        os.remove(docsMainFile)
        println("✓ Removed mdoc documentation runner")
      if os.exists(docsSrcDir) && os.list(docsSrcDir).isEmpty then
        os.remove.all(mdocDocsDir)
        println("✓ Removed mdoc-docs directory")

    // Write semantic version bump script
    val hasVersionBump =
      answers.getOrElse("version-bump", "no").toLowerCase.startsWith("y")
    val bumpScript = scriptsDir / "version-bump.scala"
    if hasVersionBump then
      val bumpContent =
        """#!/usr/bin/env scala-cli
          |
          |//> using scala 3.3.4
          |//> using dep com.lihaoyi::os-lib:0.11.8
          |
          |import os._
          |
          |object VersionBump:
          |  def main(args: Array[String]): Unit =
          |    if args.isEmpty then
          |      println("Error: bump type required (major, minor, patch)")
          |      sys.exit(1)
          |
          |    val bumpType = args.head.toLowerCase
          |    if !Seq("major", "minor", "patch").contains(bumpType) then
          |      println("Error: invalid bump type. Must be: major, minor, patch")
          |      sys.exit(1)
          |
          |    val repoRoot = os.Path(os.proc("git", "rev-parse", "--show-toplevel").call().out.text().trim)
          |    val buildSbt = repoRoot / "build.sbt"
          |    val buildSc = repoRoot / "build.sc"
          |    val projectScala = repoRoot / "project.scala"
          |
          |    var currentVersionOpt: Option[String] = None
          |    var targetFileOpt: Option[os.Path] = None
          |    var content = ""
          |
          |    if os.exists(buildSbt) then
          |      targetFileOpt = Some(buildSbt)
          |      content = os.read(buildSbt)
          |      val regex = "(?i)version\\s*:=\\s*\"(.*?)\"".r
          |      regex.findFirstMatchIn(content).foreach { m =>
          |        currentVersionOpt = Some(m.group(1))
          |      }
          |    else if os.exists(buildSc) then
          |      targetFileOpt = Some(buildSc)
          |      content = os.read(buildSc)
          |      val regex = "(?i)def\\s*publishVersion\\s*=\\s*\"(.*?)\"".r
          |      val regex2 = "(?i)val\\s*version\\s*=\\s*\"(.*?)\"".r
          |      regex.findFirstMatchIn(content).orElse(regex2.findFirstMatchIn(content)).foreach { m =>
          |        currentVersionOpt = Some(m.group(1))
          |      }
          |    else if os.exists(projectScala) then
          |      targetFileOpt = Some(projectScala)
          |      content = os.read(projectScala)
          |      val regex = "(?i)//\\s*version\\s*:=\\s*\"(.*?)\"".r
          |      regex.findFirstMatchIn(content).foreach { m =>
          |        currentVersionOpt = Some(m.group(1))
          |      }
          |
          |    val (currentVersion, targetFile) = (currentVersionOpt, targetFileOpt) match
          |      case (Some(v), Some(f)) => (v, f)
          |      case _ =>
          |        val defaultVer = "0.1.0"
          |        if os.exists(projectScala) then
          |          val updated = s"// version := \"$defaultVer\"\n" + os.read(projectScala)
          |          os.write.over(projectScala, updated)
          |          content = updated
          |          (defaultVer, projectScala)
          |        else if os.exists(buildSbt) then
          |          val updated = s"version := \"$defaultVer\"\n" + os.read(buildSbt)
          |          os.write.over(buildSbt, updated)
          |          content = updated
          |          (defaultVer, buildSbt)
          |        else
          |          println("Error: Could not locate build.sbt, build.sc, or project.scala to find version")
          |          sys.exit(1)
          |
          |    println(s"Current version: $currentVersion")
          |
          |    val parts = currentVersion.split('.').flatMap(_.toIntOption)
          |    if parts.length < 3 then
          |      println(s"Error: Version '$currentVersion' is not in standard semantic versioning format (X.Y.Z)")
          |      sys.exit(1)
          |
          |    val Array(major, minor, patch) = parts.take(3)
          |    val nextVersion = bumpType match
          |      case "major" => s"${major + 1}.0.0"
          |      case "minor" => s"$major.${minor + 1}.0"
          |      case "patch" => s"$major.$minor.${patch + 1}"
          |
          |    println(s"Bumping version to: $nextVersion")
          |
          |    val updatedContent = targetFile match
          |      case f if f == buildSbt =>
          |        content.replaceFirst("version\\s*:=\\s*\".*?\"", s"version := \"$nextVersion\"")
          |      case f if f == buildSc =>
          |        if content.contains("def publishVersion") then
          |          content.replaceFirst("def\\s*publishVersion\\s*=\\s*\".*?\"", s"def publishVersion = \"$nextVersion\"")
          |        else
          |          content.replaceFirst("val\\s*version\\s*=\\s*\".*?\"", s"val version = \"$nextVersion\"")
          |      case f if f == projectScala =>
          |        content.replaceFirst("//\\s*version\\s*:=\\s*\".*?\"", s"// version := \"$nextVersion\"")
          |      case _ => content
          |
          |    os.write.over(targetFile, updatedContent)
          |    println(s"✓ Updated version in ${targetFile.relativeTo(repoRoot)}")
          |""".stripMargin
      os.write.over(bumpScript, bumpContent)
      try { os.perms.set(bumpScript, "rwxr-xr-x") }
      catch { case _: Exception => }
      println(
        "✓ Created version bumping utility script (scripts/version-bump.scala)"
      )
    else if os.exists(bumpScript) then
      os.remove(bumpScript)
      println("✓ Removed version bumping utility script")

    // Setup Git hooks (pre-commit & pre-push)
    val hasGitHooks =
      answers.getOrElse("git-hooks", "no").toLowerCase.startsWith("y")
    val preCommitScript = scriptsDir / "git-pre-commit.scala"
    val prePushScript = scriptsDir / "git-pre-push.scala"

    val gitHooksDir = target / ".git" / "hooks"
    val gitPreCommitHook = gitHooksDir / "pre-commit"
    val gitPrePushHook = gitHooksDir / "pre-push"

    if hasGitHooks then
      // 1. Write scripts/git-pre-commit.scala
      val preCommitContent =
        """#!/usr/bin/env scala-cli
          |
          |//> using scala 3.3.4
          |//> using dep com.lihaoyi::os-lib:0.11.8
          |
          |import os._
          |
          |object GitPreCommit:
          |  def main(args: Array[String]): Unit =
          |    val repoRoot = os.Path(os.proc("git", "rev-parse", "--show-toplevel").call().out.text().trim)
          |
          |    val buildTool = if os.exists(repoRoot / "build.sbt") then "sbt"
          |                    else if os.exists(repoRoot / "build.sc") then "mill"
          |                    else "scala-cli"
          |
          |    val hasScalafmt = os.exists(repoRoot / ".scalafmt.conf")
          |    val hasScalafix = os.exists(repoRoot / ".scalafix.conf")
          |
          |    if !hasScalafmt && !hasScalafix then
          |      println("No formatting or linting configuration found. Pre-commit check skipped.")
          |      sys.exit(0)
          |
          |    println("=== Git Pre-Commit Quality Checks ===")
          |
          |    if hasScalafmt then
          |      println("Checking code formatting (Scalafmt)...")
          |      val fmtExit = buildTool match
          |        case "sbt" =>
          |          os.proc("sbt", "scalafmtCheckAll").call(cwd = repoRoot, check = false).exitCode
          |        case "scala-cli" =>
          |          os.proc("scala-cli", "fmt", "--check", ".").call(cwd = repoRoot, check = false).exitCode
          |        case "mill" =>
          |          os.proc("mill", "mill.scalalib.scalafmt.ScalafmtModule/checkFormatAll").call(cwd = repoRoot, check = false).exitCode
          |
          |      if fmtExit != 0 then
          |        println("\n[ERROR] Code formatting check failed!")
          |        println("Please run the formatting tool to fix it:")
          |        buildTool match
          |          case "sbt" => println("  sbt scalafmtAll")
          |          case "scala-cli" => println("  scala-cli fmt .")
          |          case "mill" => println("  mill mill.scalalib.scalafmt.ScalafmtModule/reformatAll")
          |        sys.exit(1)
          |
          |    if hasScalafix then
          |      println("Checking code linting (Scalafix)...")
          |      val lintExit = buildTool match
          |        case "sbt" =>
          |          os.proc("sbt", "scalafixAll --check").call(cwd = repoRoot, check = false).exitCode
          |        case "scala-cli" =>
          |          os.proc("scala-cli", "--power", "scalafix", "--check", ".").call(cwd = repoRoot, check = false).exitCode
          |        case "mill" =>
          |          os.proc("mill", "mill.scalalib.contrib.ScalafixModule/fix", "--check").call(cwd = repoRoot, check = false).exitCode
          |
          |      if lintExit != 0 then
          |        println("\n[ERROR] Code linting check failed!")
          |        println("Please run linting to fix it:")
          |        buildTool match
          |          case "sbt" => println("  sbt scalafixAll")
          |          case "scala-cli" => println("  scala-cli --power scalafix .")
          |          case "mill" => println("  mill mill.scalalib.contrib.ScalafixModule/fix")
          |        sys.exit(1)
          |
          |    println("✓ All pre-commit checks passed successfully!")
          |""".stripMargin
      os.write.over(preCommitScript, preCommitContent)
      try { os.perms.set(preCommitScript, "rwxr-xr-x") }
      catch { case _: Exception => }
      println("✓ Created pre-commit script (scripts/git-pre-commit.scala)")

      // 2. Write scripts/git-pre-push.scala
      val prePushContent =
        """#!/usr/bin/env scala-cli
          |
          |//> using scala 3.3.4
          |//> using dep com.lihaoyi::os-lib:0.11.8
          |
          |import os._
          |
          |object GitPrePush:
          |  def main(args: Array[String]): Unit =
          |    val repoRoot = os.Path(os.proc("git", "rev-parse", "--show-toplevel").call().out.text().trim)
          |
          |    val buildTool = if os.exists(repoRoot / "build.sbt") then "sbt"
          |                    else if os.exists(repoRoot / "build.sc") then "mill"
          |                    else "scala-cli"
          |
          |    println("=== Git Pre-Push Verification Checks ===")
          |    println(s"Running compilation and tests using $buildTool...")
          |
          |    val exitCode = buildTool match
          |      case "sbt" =>
          |        val hasPrePushAlias = os.read(repoRoot / "build.sbt").contains("addCommandAlias(\"prePush\"")
          |        val cmd = if hasPrePushAlias then Seq("sbt", "prePush") else Seq("sbt", "compile", "test")
          |        os.proc(cmd).call(cwd = repoRoot, check = false).exitCode
          |
          |      case "mill" =>
          |        val buildScContent = os.read(repoRoot / "build.sc")
          |        val cmd = if buildScContent.contains("def prePush") then Seq("mill", "app.prePush") else Seq("mill", "app.test")
          |        os.proc(cmd).call(cwd = repoRoot, check = false).exitCode
          |
          |      case "scala-cli" =>
          |        os.proc("scala-cli", "test", ".").call(cwd = repoRoot, check = false).exitCode
          |
          |    if exitCode != 0 then
          |      println("\n[ERROR] Pre-push verification failed! Push aborted.")
          |      sys.exit(1)
          |
          |    println("✓ All pre-push checks passed successfully!")
          |""".stripMargin
      os.write.over(prePushScript, prePushContent)
      try { os.perms.set(prePushScript, "rwxr-xr-x") }
      catch { case _: Exception => }
      println("✓ Created pre-push script (scripts/git-pre-push.scala)")

      // 3. Write Git delegate hooks in .git/hooks/ if .git exists
      if os.exists(gitHooksDir) then
        val gitPreCommitContent =
          """#!/bin/sh
            |scala-cli run scripts/git-pre-commit.scala -- "$@"
            |""".stripMargin
        os.write.over(gitPreCommitHook, gitPreCommitContent)
        try { os.perms.set(gitPreCommitHook, "rwxr-xr-x") }
        catch { case _: Exception => }

        val gitPrePushContent =
          """#!/bin/sh
            |scala-cli run scripts/git-pre-push.scala -- "$@"
            |""".stripMargin
        os.write.over(gitPrePushHook, gitPrePushContent)
        try { os.perms.set(gitPrePushHook, "rwxr-xr-x") }
        catch { case _: Exception => }
        println("✓ Installed git pre-commit and pre-push hooks to .git/hooks/")
    else
      // Cleanup
      if os.exists(preCommitScript) then os.remove(preCommitScript)
      if os.exists(prePushScript) then os.remove(prePushScript)
      if os.exists(gitPreCommitHook) then os.remove(gitPreCommitHook)
      if os.exists(gitPrePushHook) then os.remove(gitPrePushHook)
      println("✓ Cleaned up git hooks")

  def updateBuildSc(
      buildFile: os.Path,
      projectName: String,
      scalaVer: String,
      answers: Map[String, String],
      deps: List[String],
      testDeps: List[String],
      plugins: List[String]
  ): Unit =
    val crossComp =
      answers.getOrElse("cross-version", "no").toLowerCase == "yes"
    val template =
      if crossComp then
        s"""import mill._, scalalib._
         |
         |val scala3 = "$scalaVer"
         |val scala213 = "2.13.12"
         |
         |object app extends Cross[AppModule](scala3, scala213)
         |trait AppModule extends CrossScalaModule {
         |  def scalacOptions = Seq("-Ysemanticdb", "-P:wartremover:traverser:org.wartremover.warts.Unsafe", "-Werror")
         |  def ivyDeps = Agg(
         |    // [dependencies-start]
         |    // [dependencies-end]
         |  )
         |
         |  def scalacPluginIvyDeps = Agg(
         |    // [plugins-start]
         |    // [plugins-end]
         |  )
         |
         |  object test extends ScalaTests {
         |    def testFramework = "munit.Framework"
         |    def ivyDeps = Agg(
         |      // [test-dependencies-start]
         |      // [test-dependencies-end]
         |    )
         |  }
         |}
         |""".stripMargin
      else
        s"""import mill._, scalalib._
         |
         |object app extends ScalaModule {
         |  def scalaVersion = "$scalaVer"
         |  def scalacOptions = Seq("-Ysemanticdb", "-P:wartremover:traverser:org.wartremover.warts.Unsafe", "-Werror")
         |  def ivyDeps = Agg(
         |    // [dependencies-start]
         |    // [dependencies-end]
         |  )
         |
         |  def scalacPluginIvyDeps = Agg(
         |    // [plugins-start]
         |    // [plugins-end]
         |  )
         |
         |  object test extends ScalaTests {
         |    def testFramework = "munit.Framework"
         |    def ivyDeps = Agg(
         |      // [test-dependencies-start]
         |      // [test-dependencies-end]
         |    )
         |  }
         |}
         |""".stripMargin

    if !os.exists(buildFile) then os.write(buildFile, template)
    else
      val content = os.read(buildFile)
      val hasCrossModule = content.contains("CrossScalaModule")
      if hasCrossModule != crossComp then os.write.over(buildFile, template)

    var content = os.read(buildFile)

    if !crossComp then
      val scalaVerRegex = """def scalaVersion\s*=\s*"[^"]*"""".r
      content = scalaVerRegex.replaceFirstIn(
        content,
        s"""def scalaVersion = "$scalaVer""""
      )

    if !content.contains("scalacOptions") then
      if content.contains("extends ScalaModule") then
        content = content.replace(
          "extends ScalaModule {",
          "extends ScalaModule {\n  def scalacOptions = Seq(\"-Ysemanticdb\", \"-P:wartremover:traverser:org.wartremover.warts.Unsafe\", \"-Werror\")"
        )
      else if content.contains("extends CrossScalaModule") then
        content = content.replace(
          "extends CrossScalaModule {",
          "extends CrossScalaModule {\n  def scalacOptions = Seq(\"-Ysemanticdb\", \"-P:wartremover:traverser:org.wartremover.warts.Unsafe\", \"-Werror\")"
        )
    else if !content.contains("-Werror") then
      if content.contains("traverser:org.wartremover.warts.Unsafe") then
        content = content.replace(
          "Seq(\"-Ysemanticdb\", \"-P:wartremover:traverser:org.wartremover.warts.Unsafe\")",
          "Seq(\"-Ysemanticdb\", \"-P:wartremover:traverser:org.wartremover.warts.Unsafe\", \"-Werror\")"
        )
      else
        content = content.replace(
          "Seq(\"-Ysemanticdb\")",
          "Seq(\"-Ysemanticdb\", \"-Werror\")"
        )
    if !content.contains("wartremover") then
      content = content.replace(
        "Seq(\"-Ysemanticdb\")",
        "Seq(\"-Ysemanticdb\", \"-P:wartremover:traverser:org.wartremover.warts.Unsafe\")"
      )

    def addDepToContent(section: String, dep: String): Unit =
      val depPart = dep.split("::").head
      if !content.contains(depPart) then
        val startMarker = s"// [$section-start]"
        if content.contains(startMarker) then
          content =
            content.replace(startMarker, s"$startMarker\n    ivy\"$dep\",")
          println(s"✓ Added dependency to build.sc: $dep")

    deps.foreach(dep => addDepToContent("dependencies", dep))
    testDeps.foreach(dep => addDepToContent("test-dependencies", dep))
    plugins.foreach(plugin => addDepToContent("plugins", plugin))

    val hasMdoc = answers.getOrElse("mdoc", "no").toLowerCase.startsWith("y")
    if hasMdoc then
      val millMdocModule =
        """
          |object docs extends ScalaModule {
          |  def scalaVersion = "3.3.4"
          |  def ivyDeps = Agg(ivy"org.scalameta::mdoc:2.9.0")
          |}
          |""".stripMargin
      if !content.contains("object docs extends ScalaModule") then
        content = content + "\n" + millMdocModule

    if !content.contains("def prePush") then
      val prePushTask =
        if crossComp then """
          |def prePush() = T.command {
          |  app(scala3).compile()
          |  app(scala3).test.test()()
          |}
          |""".stripMargin
        else """
          |def prePush() = T.command {
          |  app.compile()
          |  app.test.test()()
          |}
          |""".stripMargin
      content = content + "\n" + prePushTask

    os.write.over(buildFile, content)

  def updateBuildSbt(
      sbtFile: os.Path,
      projectName: String,
      scalaVer: String,
      answers: Map[String, String],
      deps: List[String],
      testDeps: List[String],
      plugins: List[String]
  ): Unit =
    val crossComp =
      answers.getOrElse("cross-version", "no").toLowerCase == "yes"
    val scalaVersionsStr =
      if crossComp then s"""Seq("$scalaVer", "2.13.12")"""
      else s"""Seq("$scalaVer")"""

    val template =
      s"""name := "$projectName"
         |version := "0.1.0-SNAPSHOT"
         |
         |scalaVersion := "$scalaVer"
         |crossScalaVersions := $scalaVersionsStr
         |
         |scalacOptions ++= Seq("-Ysemanticdb", "-Werror")
         |
         |wartremoverErrors ++= Warts.unsafe
         |
         |libraryDependencies ++= Seq(
         |  // [dependencies-start]
         |  // [dependencies-end]
         |)
         |
         |// [plugins-start]
         |// [plugins-end]
         |
         |// Test settings
         |libraryDependencies ++= Seq(
         |  // [test-dependencies-start]
         |  // [test-dependencies-end]
         |).map(_ % Test)
         |""".stripMargin

    if !os.exists(sbtFile) then
      os.write(sbtFile, template)
      val projDir = sbtFile / os.up / "project"
      os.makeDir.all(projDir)
      os.write.over(projDir / "build.properties", "sbt.version=1.9.8\n")
      val buildSc = sbtFile / os.up / "build.sc"
      if os.exists(buildSc) then os.remove(buildSc)

    var content = os.read(sbtFile)

    if !content.contains("wartremoverErrors") then
      content = content.replace(
        "scalacOptions ++= Seq(\"-Ysemanticdb\")",
        "scalacOptions ++= Seq(\"-Ysemanticdb\")\n\nwartremoverErrors ++= Warts.unsafe"
      )

    if !content.contains("-Werror") then
      content = content.replace(
        "scalacOptions ++= Seq(\"-Ysemanticdb\")",
        "scalacOptions ++= Seq(\"-Ysemanticdb\", \"-Werror\")"
      )

    def addDepToSbt(section: String, dep: String): Unit =
      val depPart = dep.split("::").head
      if !content.contains(depPart) then
        val startMarker = s"// [$section-start]"
        if content.contains(startMarker) then
          val sbtDep = convertToSbtDep(dep)
          content = content.replace(startMarker, s"$startMarker\n  $sbtDep,")
          println(s"✓ Added dependency to build.sbt: $sbtDep")

    deps.foreach(dep => addDepToSbt("dependencies", dep))
    testDeps.foreach(dep => addDepToSbt("test-dependencies", dep))

    val pluginsSbt = sbtFile / os.up / "project" / "plugins.sbt"
    var pluginsContent =
      if os.exists(pluginsSbt) then os.read(pluginsSbt) else ""

    val requiredPlugins = List(
      "addSbtPlugin(\"ch.epfl.scala\" % \"sbt-scalafix\" % \"0.11.1\")",
      "addSbtPlugin(\"org.scalameta\" % \"sbt-scalafmt\" % \"2.5.2\")",
      "addSbtPlugin(\"org.wartremover\" % \"sbt-wartremover\" % \"3.2.5\")"
    )

    requiredPlugins.foreach { p =>
      val pPart = p.split("%")(1).trim.replace("\"", "")
      if !pluginsContent.contains(pPart) then
        pluginsContent += s"\n$p"
        println(s"✓ Added plugin to project/plugins.sbt: $pPart")
    }

    plugins.foreach { plugin =>
      val pluginPart = plugin.split("::").head
      if !pluginsContent.contains(pluginPart) then
        val sbtPlugin = convertToSbtPlugin(plugin)
        pluginsContent += s"\naddSbtPlugin($sbtPlugin)"
        println(s"✓ Added plugin to project/plugins.sbt: $sbtPlugin")
    }

    val parentDir = pluginsSbt / os.up
    if !os.exists(parentDir) then os.makeDir.all(parentDir)
    os.write.over(pluginsSbt, pluginsContent)

    val hasMdoc = answers.getOrElse("mdoc", "no").toLowerCase.startsWith("y")
    if hasMdoc then
      val sbtMdocProject =
        s"""
           |lazy val docs = (project in file("mdoc-docs"))
           |  .disablePlugins(wartremover.WartRemover)
           |  .settings(
           |    name := "$projectName-docs",
           |    publish / skip := true,
           |    scalaVersion := "3.3.4",
           |    Compile / run / fork := true,
           |    Compile / run / baseDirectory := (ThisBuild / baseDirectory).value,
           |    libraryDependencies += "org.scalameta" %% "mdoc" % "2.9.0"
           |  )
           |""".stripMargin
      if !content.contains("lazy val docs =") then
        content = content + "\n" + sbtMdocProject

    if !content.contains("addCommandAlias(\"prePush\"") then
      content =
        content + "\n\naddCommandAlias(\"prePush\", \"; compile ; test\")"

    os.write.over(sbtFile, content)

  def convertToSbtDep(dep: String): String =
    val parts = dep.split("::")
    if parts.length >= 2 then
      val org = parts(0)
      val rest = parts(1).split(":")
      val name = rest(0).stripPrefix(":")
      val ver = rest.last
      s""""$org" %% "$name" % "$ver""""
    else
      val parts2 = dep.split(":")
      if parts2.length >= 2 then
        s""""${parts2(0)}" % "${parts2(1)}" % "${parts2.last}""""
      else s""""$dep""""

  def convertToSbtPlugin(plugin: String): String =
    val sbtDep = convertToSbtDep(plugin)
    s"compilerPlugin($sbtDep)"

  def updateScalaCli(
      projectFile: os.Path,
      scalaVer: String,
      deps: List[String],
      testDeps: List[String],
      plugins: List[String]
  ): Unit =
    var lines = List(
      s"//> using scala $scalaVer",
      "//> using options -Ysemanticdb",
      "//> using options -P:wartremover:traverser:org.wartremover.warts.Unsafe",
      "// //> using options -Werror",
      "//> using exclude Setup.scala",
      "//> using exclude scripts",
      "//> using exclude mdoc-docs",
      "//> using exclude website"
    )

    deps.foreach { dep =>
      lines = lines :+ s"//> using dep $dep"
    }
    testDeps.foreach { dep =>
      lines = lines :+ s"//> using test.dep $dep"
    }
    plugins.foreach { plugin =>
      lines = lines :+ s"//> using plugin $plugin"
    }

    os.write.over(projectFile, lines.mkString("\n") + "\n")
    println(s"✓ Generated Scala CLI config: project.scala")

  def setupGit(target: os.Path): Unit =
    if !os.exists(target / ".git") then
      os.proc("git", "init").call(cwd = target)
    os.proc("git", "add", ".").call(cwd = target)

  def generateLlmRules(answers: Map[String, String], scalaVer: String): String =
    val sb = new java.lang.StringBuilder()
    sb.append("# Scala 3 LLM Guidelines & Coding Rules\n\n")
    sb.append(
      "You are acting as an expert Scala engineer. When writing, refactoring, or reviewing Scala code in this codebase, you must follow these rules strictly:\n\n"
    )

    sb.append("## 1. Syntax & Style\n")
    sb.append(
      "* Syntax and coding styles are controlled automatically by Scalafmt and Scalafix linting rules. Do not manually format code in ways that violate these configurations; rely on automatic formatting and fixing tools.\n\n"
    )

    sb.append("## 2. Functional Programming Standards\n")
    sb.append(
      "* **Pure FP Style**: Always write code in a pure functional programming style.\n"
    )
    sb.append(
      "* **Consequences**: Avoid mutable state (`var`), handle all side effects explicitly, never return or use `null`, and represent errors explicitly using type-safe structures like `Either`, `Try`, or monadic effects.\n\n"
    )

    val crossComp =
      answers.getOrElse("cross-version", "no").toLowerCase == "yes"
    if crossComp then
      sb.append("## 3. Cross-Version Compilation (Scala 2.13 & Scala 3)\n")
      sb.append(
        "* Ensure all code is compatible with both Scala 2.13 and Scala 3.\n"
      )
      sb.append(
        "* Avoid using Scala 3 exclusive features (such as `enum`, `given`/`using` (unless backported or conditionally compiled), export clauses, parameter untupling) that break Scala 2.13 compilation.\n"
      )
      sb.append("* Use cross-compatible styles for syntax where possible.\n\n")
    else
      sb.append("## 3. Scala 3 Features\n")
      sb.append(
        "* Feel free to use advanced Scala 3 features: `given`/`using` for implicits, `enum` for ADTs, extension methods, type lambdas, and union/intersection types.\n\n"
      )

    val eco = answers.getOrElse("ecosystem", "none").toLowerCase
    if eco == "typelevel" then
      sb.append("## 4. Cats & Cats Effect (Typelevel Ecosystem)\n")
      sb.append(
        "* Use Cats Effect for managing side effects and concurrency.\n"
      )
      sb.append(
        "* **Abstraction First**: Prefer programming to abstract typeclasses (e.g., `Monad`, `Sync`, `Concurrent`, `Temporal`, `ApplicativeError`) instead of concrete types/instances (like `IO`) to ensure generic, composable, and easily testable code.\n"
      )
      sb.append(
        "* Avoid running IO unsafely (never call `unsafeRunSync`). Let the runtime execute the IO at the application entry point (`IOApp`).\n"
      )
      sb.append(
        "* Use cats syntax import (`import cats.syntax.all.*`) for map, flatMap, traverse, sequence, etc.\n\n"
      )
    else if eco == "zio" then
      sb.append("## 4. ZIO Ecosystem\n")
      sb.append(
        "* Use `zio.ZIO` to model all side effects. Do not use `scala.concurrent.Future`.\n"
      )
      sb.append(
        "* Prefer `ZIO[R, E, A]` to represent environment `R`, error `E`, and value `A`.\n"
      )
      sb.append(
        "* Manage dependencies and application services using `ZLayer`.\n"
      )
      sb.append(
        "* Handle errors using ZIO's built-in error channels (failures vs. defects).\n"
      )
      sb.append(
        "* Avoid unsafe execution of ZIO effects (never use `Runtime.default.unsafe.run`).\n\n"
      )
    else
      sb.append("## 4. Standard Library Concurrency & IO\n")
      sb.append(
        "* Use standard library concurrency primitives, prefer `scala.concurrent.Future` or pure state transitions.\n"
      )
      sb.append(
        "* If using `Future`, ensure an implicit `ExecutionContext` is provided correctly.\n\n"
      )

    val hasWebServer =
      answers.getOrElse("web-server", "no").toLowerCase.startsWith("y")
    if hasWebServer then
      sb.append("## 5. Web Server\n")
      if eco == "typelevel" then
        sb.append(
          "* Use **Http4s Ember** for defining routes and serving HTTP.\n"
        )
        sb.append(
          "* Use http4s DSL (`import org.http4s.dsl.io.*`) for routing.\n"
        )
        sb.append(
          "* Integrate with Circe for JSON serialization/deserialization.\n\n"
        )
      else if eco == "zio" then
        sb.append("* Use **ZIO-HTTP** for defining routes and serving HTTP.\n")
        sb.append(
          "* Compose routes using ZIO-HTTP's DSL (`Routes` / `Method` pattern).\n\n"
        )
      else
        sb.append(
          "* Use standard web framework library APIs configured in the build tool.\n\n"
        )

    val hasWebClient =
      answers.getOrElse("web-client", "no").toLowerCase.startsWith("y")
    if hasWebClient then
      sb.append("## 6. Web Client\n")
      if eco == "typelevel" then
        sb.append(
          "* Use **Http4s Ember Client** or **STTP** with Http4s backend for outgoing HTTP requests.\n"
        )
        sb.append("* Manage client lifecycle properly using `Resource`.\n\n")
      else if eco == "zio" then
        sb.append(
          "* Use **STTP** with ZIO backend (`SttpBackend[Task, ...]` or similar) or ZIO-HTTP client.\n\n"
        )
      else
        sb.append(
          "* Use **STTP Core** or standard HTTP client for outgoing HTTP requests.\n\n"
        )

    val hasDb = answers.getOrElse("db-access", "no").toLowerCase.startsWith("y")
    if hasDb then
      sb.append("## 7. Database Access\n")
      if eco == "typelevel" then
        sb.append("* Use **Doobie** for type-safe database queries.\n")
        sb.append("* Write SQL queries using the `sql` interpolator.\n")
        sb.append(
          "* Use `transact` to run connection IOs inside a transaction.\n\n"
        )
      else if eco == "zio" then
        sb.append("* Use **Quill** with JDBC ZIO for database access.\n")
        sb.append("* Define queries using Quill's compile-time quotations.\n\n")
      else
        sb.append(
          "* Use **PostgreSQL JDBC** or standard database libraries.\n\n"
        )

    val hasServerless =
      answers.getOrElse("serverless-run", "no").toLowerCase.startsWith("y")
    if hasServerless then
      sb.append("## 8. Serverless Deployment (AWS Lambda)\n")
      sb.append(
        "* Structure handlers using AWS Lambda Java Core (`RequestHandler` or `RequestStreamHandler`).\n"
      )
      sb.append(
        "* Keep initialization logic outside the handler to minimize cold starts.\n\n"
      )

    val testTools = answers.getOrElse("test-tools", "none").toLowerCase
    if testTools.contains("munit") || testTools.contains("shapeless") then
      sb.append("## 9. Testing Guidelines (MUnit)\n")
      sb.append("* Write tests using **MUnit**. Extend `munit.FunSuite`.\n")
      sb.append(
        "* **Preferred Styles**: Prefer Property-Based (PB) testing, Golden (snapshot) testing, and mutation testing via Stryker4s.\n"
      )
      sb.append(
        "* **Formal Verification**: Search for opportunities to apply Stainless formal verification to functional properties and core logic.\n"
      )
      sb.append(
        "* Leverage MUnit assertions like `assertEquals`, `assertNotEquals`, `intercept`.\n\n"
      )
    else if testTools.contains("zio") then
      sb.append("## 9. Testing Guidelines (ZIO Test)\n")
      sb.append("* Write tests using **ZIO Test**. Extend `ZIOSpecDefault`.\n")
      sb.append(
        "* **Preferred Styles**: Prefer Property-Based (PB) testing, Golden (snapshot) testing, and mutation testing via Stryker4s.\n"
      )
      sb.append(
        "* **Formal Verification**: Search for opportunities to apply Stainless formal verification to functional properties and core logic.\n"
      )
      sb.append("* Use assertion macros like `assertZIO`, `assertTrue`.\n\n")
    else
      sb.append("## 9. Testing Guidelines\n")
      sb.append(
        "* **Preferred Styles**: Prefer Property-Based (PB) testing, Golden (snapshot) testing, and mutation testing via Stryker4s.\n"
      )
      sb.append(
        "* **Formal Verification**: Search for opportunities to apply Stainless formal verification to functional properties and core logic.\n\n"
      )

    val hasStainless =
      answers.getOrElse("stainless", "no").toLowerCase.startsWith("y")
    if hasStainless then
      sb.append("## 10. Formal Verification (Stainless)\n")
      sb.append("* Write pure mathematical specifications.\n")
      sb.append(
        "* Annotate verified code with `@pure`, `@ghost`, or `@extern` where appropriate.\n"
      )
      sb.append(
        "* Avoid mutable state or unsupported Scala features in verified code sections.\n\n"
      )

    val hasStryker =
      answers.getOrElse("stryker", "no").toLowerCase.startsWith("y")
    if hasStryker then
      sb.append("## 11. Mutation Testing (Stryker)\n")
      sb.append(
        "* Write comprehensive tests that verify behavior under mutation.\n"
      )
      sb.append("* Ensure tests are not brittle or order-dependent.\n\n")

    val hasJmh =
      answers.getOrElse("performance-testing", "no").toLowerCase.startsWith("y")
    if hasJmh then
      sb.append("## 12. Performance & JMH Benchmarking\n")
      sb.append("* Use JMH for microbenchmarks.\n")
      sb.append(
        "* Annotate benchmark classes with `@State(Scope.Thread)` and methods with `@Benchmark`.\n"
      )
      sb.append(
        "* Avoid side effects or compiler optimizations (like dead code elimination) from skewing benchmark results (use `Blackhole` if necessary).\n\n"
      )

    sb.append("## 13. Code Quality (Scalafmt, Scalafix, Wartremover)\n")
    sb.append("* Keep code formatted via Scalafmt rules.\n")
    sb.append(
      "* Use Scalafix to organize imports and remove unused imports or syntax warnings automatically.\n"
    )
    sb.append(
      "* **Wartremover**: Pure functional programming safety is checked via Wartremover's Unsafe warts. Ensure your code does not trigger any unsafe warts (such as `Null`, `Var`, `Throw`, `Return`, `IsInstanceOf`, `AsInstanceOf`).\n\n"
    )

    val hasOptics =
      answers.getOrElse("optics", "no").toLowerCase.startsWith("y")
    if hasOptics then
      sb.append("## 14. Immutable Data Optics (Monocle)\n")
      sb.append(
        "* Use Monocle lenses, prisms, and optionals to modify deeply nested immutable structures instead of nested `copy` calls.\n\n"
      )

    val hasDto =
      answers.getOrElse("dto-mapping", "no").toLowerCase.startsWith("y")
    if hasDto then
      sb.append("## 15. Data Transformation (Chimney)\n")
      sb.append(
        "* Use Chimney for type-safe data transformations (`transformInto`) between DTOs, API models, and Domain models.\n\n"
      )

    val hasApiDocs =
      answers.getOrElse("api-docs", "no").toLowerCase.startsWith("y")
    if hasApiDocs then
      sb.append("## 16. API Specifications (Tapir)\n")
      sb.append(
        "* Define endpoints using Tapir for declarative, type-safe API descriptions.\n"
      )
      sb.append("* Generate OpenAPI documentation from Tapir endpoints.\n\n")

    val hasMcp =
      answers.getOrElse("mcp-tools", "no").toLowerCase.startsWith("y")
    if hasMcp then
      sb.append("## 18. ScalaSemantic MCP Rules\n")
      sb.append(
        "* For any Scala (`.scala`) source questions, file operations, search, or analysis, use ScalaSemantic MCP tools before shell text tools.\n"
      )
      sb.append(
        "* Preferably compile code before usage, therefore more ScalaSemantic functions could be used with better result.\n"
      )
      sb.append(
        "* **NEVER** use generic text/file-reading, viewing, or searching tools (like `view_file`, `grep_search`, or shell commands like `rg`/`grep`/`cat`/`sed`) on `.scala` files unless the MCP tools are unavailable or failing.\n"
      )
      sb.append(
        "* **ALWAYS** use the custom tools provided by the `scala-semantic` MCP server:\n"
      )
      sb.append(
        "  * **To read/view the contents of a file**: Use the `annotated_source` MCP tool.\n"
      )
      sb.append(
        "  * **For all other queries** (searching, finding usages, hierarchies, etc.): Select the appropriate tool from the registered `scala-semantic` MCP tools.\n\n"
      )

    sb.append("## 17. Project Maintenance\n")
    sb.append(
      "* **Scala Steward**: Periodically run Scala Steward updates to keep the project's dependencies and compiler plugins up-to-date.\n\n"
    )

    sb.append("## 19. Command Execution & Token Output Minimization\n")
    sb.append(
      "* **Minimize Output Volume**: To prevent token bloat, always minimize stdout/stderr output when running commands. Avoid dumping massive log streams, command traces, or verbose build success messages into the LLM context.\n"
    )
    sb.append(
      "* **Use Token-Optimized CLI Proxies**: If `rtk` (Rust Token Killer) is installed and verified, prefix commands with `rtk` (e.g. `rtk git status`, `rtk sbt test`) to leverage transparent token-filtering proxying.\n"
    )
    sb.append(
      "* **Filter Log Streams & Errors**: When running tests, compiles, or other scripts, redirect or pipe outputs to isolate errors or limit lines:\n"
    )
    sb.append(
      "  * Pipe compile/test logs to `grep` with context flags to capture only errors (e.g., `| grep -C 3 -i error` or `| grep -i fail`).\n"
    )
    sb.append(
      "  * Use `head -n N` or `tail -n N` to capture only a small, representative slice of command outputs when scanning general outputs.\n"
    )
    sb.append(
      "  * Suppress standard success logs or stdout using redirect syntax (`> /dev/null`) if you only need the command exit status or error streams.\n\n"
    )

    sb.toString()

  def updateGuideFile(file: os.Path, answers: Map[String, String]): Unit =
    if os.exists(file) then
      var content = os.read(file)

      val buildTool = answers.getOrElse("build-tool", "mill").toLowerCase
      val hasStryker =
        answers.getOrElse("stryker", "no").toLowerCase.startsWith("y")
      val hasFormatting = true
      val hasLinting = true

      val compileCmd =
        if buildTool == "sbt" then "sbt compile"
        else if buildTool == "scala-cli" then "scala-cli compile ."
        else "mill app.compile"

      val runCmd =
        if buildTool == "sbt" then "sbt run"
        else if buildTool == "scala-cli" then "scala-cli run ."
        else "mill app.run"

      val testCmd =
        if buildTool == "sbt" then "sbt test"
        else if buildTool == "scala-cli" then "scala-cli test ."
        else "mill app.test"

      val strykerRow = if hasStryker then
        val cmd = if buildTool == "sbt" then "sbt stryker" else "stryker4s run"
        s"\n| **Run Mutation Tests** | `$cmd` |"
      else ""

      val formatRow = if hasFormatting then
        val cmd =
          if buildTool == "sbt" then "sbt scalafmtAll"
          else if buildTool == "scala-cli" then "scala-cli fmt ."
          else "mill mill.scalalib.ScalafmtModule/reformat"
        s"\n| **Format Code** | `$cmd` |"
      else ""

      val lintRow = if hasLinting then
        val cmd =
          if buildTool == "sbt" then "sbt scalafixAll"
          else if buildTool == "scala-cli" then "scala-cli --power scalafix ."
          else "mill mill.scalalib.contrib.ScalafixModule/fix"
        s"\n| **Lint Code** | `$cmd` |"
      else ""

      val hasMdoc = answers.getOrElse("mdoc", "no").toLowerCase.startsWith("y")
      val mdocRow = if hasMdoc then
        val cmd =
          if buildTool == "sbt" then "sbt docs/run"
          else if buildTool == "scala-cli" then
            "scala-cli run mdoc-docs/src/main/scala/DocsMain.scala -- ."
          else "mill docs.run"
        s"\n| **Compile Docs (Mdoc)** | `$cmd` |"
      else ""

      val wtStartRow =
        "\n| **Start Git Worktree** | `scala-cli run scripts/worktree-start.scala -- <branch>` |"
      val wtFinishRow =
        "\n| **Finish Git Worktree** | `scala-cli run scripts/worktree-finish.scala` |"

      val newCommandsSection =
        s"""## 1. Key Commands
           |
           |Use the following commands to build, test, and format the project:
           |
           || Operation | Command |
           || :--- | :--- |
           || **Compile Project** | `$compileCmd` |
           || **Run Application** | `$runCmd` |
           || **Run Unit Tests** | `$testCmd` |
           || **Run Scala Steward** | `scala-steward` |""".stripMargin + strykerRow + formatRow + lintRow + mdocRow + wtStartRow + wtFinishRow

      // Replace from "## 1. Key Commands" to the next "---" (skipping the "---" inside the table header)
      val startIdx = content.indexOf("## 1. Key Commands")
      if startIdx != -1 then
        val endIdx = {
          val idx1 = content.indexOf("\n---", startIdx)
          val idx2 = content.indexOf("\r\n---", startIdx)
          if idx1 != -1 && idx2 != -1 then Math.min(idx1, idx2)
          else if idx1 != -1 then idx1
          else idx2
        }
        if endIdx != -1 then
          content =
            content.substring(0, startIdx) + newCommandsSection + "\n" + content
              .substring(endIdx)

      val mcpEnabled =
        answers.getOrElse("mcp-tools", "no").toLowerCase.startsWith("y")
      val hookEnabled =
        answers.getOrElse("interaction-hook", "no").toLowerCase.startsWith("y")

      val mcpBullet =
        if mcpEnabled then
          "\n*   **ScalaSemantic MCP configuration:** [.agents/mcp_config.json](.agents/mcp_config.json) (runs compile-aware AI search)."
        else ""
      val hookBullet =
        if hookEnabled then
          "\n*   **LLM Interaction Hook:** [scripts/log-scala-interaction.scala](scripts/log-scala-interaction.scala) (logs AI commands to study reading vs editing)."
        else ""
      val mdocBullet =
        if hasMdoc then
          "\n*   **Mdoc documentation:** [docs/index.md](docs/index.md) (source markdown compiled by mdoc)."
        else ""
      val wtStartBullet =
        "\n*   **Start Worktree Script:** [scripts/worktree-start.scala](scripts/worktree-start.scala) (creates isolated task branch + worktree)."
      val wtFinishBullet =
        "\n*   **Finish Worktree Script:** [scripts/worktree-finish.scala](scripts/worktree-finish.scala) (commits, merges, and cleans up the worktree)."

      val newLlmSection =
        s"""## 3. LLM Configuration & Workspace Rules
           |
           |This project uses local LLM instructions and workspace rules tailored to the selected features:
           |*   **Antigravity/Gemini Rules:** [.agents/AGENTS.md](.agents/AGENTS.md)
           |*   **Cursor Rules:** [.cursorrules](.cursorrules)
           |*   **Global/Generic Rules:** [scala-rules.md](scala-rules.md)$mcpBullet$hookBullet$mdocBullet$wtStartBullet$wtFinishBullet
           |
           |All rules and guidelines are automatically kept in sync by the `Setup.scala` tool when features are added or removed.
           |""".stripMargin

      val startRulesIdx = content.indexOf("## 3. LLM Configuration")
      if startRulesIdx != -1 then
        content = content.substring(0, startRulesIdx) + newLlmSection
      else
        // Try fallback with the old section name
        val startRulesIdxFallback =
          content.indexOf("## 3. LLM Configuration & Shared Rules")
        if startRulesIdxFallback != -1 then
          content = content.substring(0, startRulesIdxFallback) + newLlmSection

      val finalContent = content.replace("$$targetDir", ".")
      os.write.over(file, finalContent)
      println(
        s"✓ Updated key commands and LLM instructions section in ${file.last}"
      )
