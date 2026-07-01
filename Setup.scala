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
  val githubRulesUrl = "https://raw.githubusercontent.com/MercurieVV/scala-llm-template/master/scala-rules.md"

  var defaultScalaVersion = "3.3.3"

  def getFeaturesList: List[Feature] = List(
    // 1. Language & Compiler Core
    Feature("scala-version", "Core", "Scala Version", "Enter Scala version", defaultScalaVersion),
    Feature("cross-version", "Core", "Cross Version Compilation", "Enable cross version compilation? (yes/no)", "no"),
    Feature("build-tool", "Core", "Build Tool", "Primary build tool (mill/sbt/scala-cli)", "mill"),
    Feature("scripts", "Core", "Scripting Tool", "Scripting wrapper (scala-cli/none)", "none"),
    Feature("github-flow", "Core", "GitHub Flow Integration", "Enable GitHub Flow (CI Workflow)? (yes/no)", "no"),

    // 2. Ecosystem & Frameworks
    Feature("ecosystem", "Ecosystem", "Primary Ecosystem", "Ecosystem (typelevel, zio, none)", "none"),
    Feature("web-server", "Ecosystem", "Web Server", "Enable Web Server? (yes/no)", "no"),
    Feature("web-client", "Ecosystem", "Web Client", "Enable Web Client? (yes/no)", "no"),
    Feature("db-access", "Ecosystem", "Database Access", "Enable Database Access? (yes/no)", "no"),
    Feature("serverless-run", "Ecosystem", "Serverless Deployment", "Enable Serverless run? (yes/no)", "no"),

    // 3. Verification & Quality Assurance
    Feature("test-tools", "Quality Assurance", "Testing Framework", "Test tools (munit+shapeless, zio-test, none)", "none"),
    Feature("stainless", "Quality Assurance", "Stainless Verification", "Enable Stainless formal verification? (yes/no)", "no"),
    Feature("stryker", "Quality Assurance", "Stryker Mutation Testing", "Enable Stryker mutation testing? (yes/no)", "no"),
    Feature("performance-testing", "Quality Assurance", "JMH Performance Testing", "Enable JMH performance testing? (yes/no)", "no"),

    // 4. Proposed Utilities (Additions)
    Feature("formatting", "Developer Tooling", "Scalafmt Formatting", "Enable Scalafmt configuration? (yes/no)", "yes"),
    Feature("linting", "Developer Tooling", "Scalafix Linter", "Enable Scalafix? (yes/no)", "no"),
    Feature("optics", "Data Utilities", "Monocle Optics", "Enable Monocle (lenses/optics for immutable structures)? (yes/no)", "no"),
    Feature("dto-mapping", "Data Utilities", "Chimney DTO Mapping", "Enable Chimney (type-safe data transformation)? (yes/no)", "no"),
    Feature("api-docs", "Ecosystem", "Tapir API Documentation", "Enable Tapir (declarative endpoints)? (yes/no)", "no")
  )

  def main(args: Array[String]): Unit =
    println("=== Scala Project Setup & Update (Mill/SBT/Scala-CLI + Global Rules) ===")

    // Determine target directory
    val targetDir = args.headOption match
      case Some(".") | None => os.pwd
      case Some(path) => 
        val d = os.Path(path, os.pwd)
        if !os.exists(d) then os.makeDir.all(d)
        d

    val projectName = targetDir.last
    val buildFile = targetDir / "build.sc"
    val buildSbtFile = targetDir / "build.sbt"
    val projectScalaFile = targetDir / "project.scala"
    val isExisting = os.exists(buildFile) || os.exists(buildSbtFile) || os.exists(projectScalaFile)

    if isExisting then
      println(s"Found existing project in $targetDir. Switching to update mode.")
    else
      println(s"Initializing new project in $targetDir...")

    // 1. Resolve latest stable Scala version
    println("Resolving latest stable Scala 3 version from Maven Central...")
    fetchLatestStableVersion("org.scala-lang", "scala3-compiler_3") match
      case Some(ver) => 
        println(s"✓ Found latest stable Scala 3 version: $ver")
        defaultScalaVersion = ver
      case None => 
        println("⚠️ Could not fetch latest Scala version. Using offline fallback: 3.3.3")
        defaultScalaVersion = "3.3.3"

    // 2. Fetch/Update Master Rules in the SHARED folder
    updateMasterRules()

    // 3. Q&A Loop for Features (Grouped output, with detected defaults)
    val featuresToPrompt = detectExistingDefaults(targetDir, getFeaturesList)
    val answers = promptFeaturesGrouped(featuresToPrompt)

    // 4. Setup Project Structure (folders, configs)
    setupStructure(targetDir, answers)

    // 5. Resolve dependencies dynamically once
    val selectedScalaVer = answers.getOrElse("scala-version", defaultScalaVersion)
    val (resolvedDeps, resolvedTestDeps, resolvedPlugins) = getDependenciesAndPlugins(answers, selectedScalaVer)

    // 6. Create/Update Build Files based on selected Build Tool
    val buildTool = answers.getOrElse("build-tool", "mill").toLowerCase

    if buildTool == "sbt" then
      updateBuildSbt(targetDir / "build.sbt", projectName, selectedScalaVer, answers, resolvedDeps, resolvedTestDeps, resolvedPlugins)
      val buildSc = targetDir / "build.sc"
      if os.exists(buildSc) then os.remove(buildSc)
    else if buildTool == "scala-cli" then
      updateScalaCli(targetDir / "project.scala", selectedScalaVer, resolvedDeps, resolvedTestDeps, resolvedPlugins)
      val buildSc = targetDir / "build.sc"
      if os.exists(buildSc) then os.remove(buildSc)
      val buildSbt = targetDir / "build.sbt"
      if os.exists(buildSbt) then os.remove(buildSbt)
    else
      // mill
      updateBuildSc(buildFile, projectName, selectedScalaVer, answers, resolvedDeps, resolvedTestDeps, resolvedPlugins)
      val buildSbt = targetDir / "build.sbt"
      if os.exists(buildSbt) then os.remove(buildSbt)

    // Setup Scala CLI config if selected separately
    val hasScalaCli = answers.getOrElse("scripts", "none").toLowerCase == "scala-cli" || buildTool == "scala-cli"
    if hasScalaCli then
      updateScalaCli(targetDir / "project.scala", selectedScalaVer, resolvedDeps, resolvedTestDeps, resolvedPlugins)
    else
      val psc = targetDir / "project.scala"
      if os.exists(psc) then os.remove(psc)

    // 7. Setup Git (Stage changes)
    setupGit(targetDir)

    println(s"\n=== Setup Completed Successfully! ===")
    println(s"Project Location: $targetDir")
    println(s"Selected Scala Version: $selectedScalaVer")
    println(s"Build Tool Configured: ${buildTool.toUpperCase}")
    println("\nRules have been configured globally in the shared folder:")
    println(s"  $masterRulesFile")
    println("\nNo symlinks or rule files were created inside the project folder.")
    if buildTool == "sbt" then
      println("Run 'sbt test' to verify and compile.")
    else if buildTool == "scala-cli" then
      println("Run 'scala-cli test .' to verify and compile.")
    else
      println("Run 'mill app.test' to verify and compile.")

  def updateMasterRules(): Unit =
    if !os.exists(rulesDir) then os.makeDir.all(rulesDir)
    println(s"Synchronizing shared master rules at $masterRulesFile...")
    try
      val content = clippyFetch(githubRulesUrl)
      os.write.over(masterRulesFile, content)
      println("✓ Rules synchronized from GitHub.")
    catch
      case _: Exception =>
        println("⚠️ Could not fetch rules from GitHub. Using/creating local cache.")
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
    val p = os.proc("curl", "-fsSL", "--connect-timeout", "3", url).call(stderr = os.Pipe)
    if p.exitCode == 0 then p.out.text()
    else throw new RuntimeException("Fetch failed")

  def promptFeaturesGrouped(features: List[Feature]): Map[String, String] =
    val grouped = features.groupBy(_.group)
    val orderedGroups = List("Core", "Ecosystem", "Quality Assurance", "Data Utilities", "Developer Tooling")
    
    var answers = Map.empty[String, String]
    
    orderedGroups.foreach { groupName =>
      grouped.get(groupName).foreach { list =>
        println(s"\n--- $groupName Options ---")
        list.foreach { f =>
          val rawInput = readLine(s"  ${f.name} [${f.prompt}] (default: ${f.defaultValue}): ")
          val response = if rawInput == null then "" else rawInput.trim
          val finalVal = if response.isEmpty then f.defaultValue else response
          answers = answers + (f.id -> finalVal)
        }
      }
    }
    answers

  def detectExistingDefaults(target: os.Path, features: List[Feature]): List[Feature] =
    val buildScFile = target / "build.sc"
    val buildSbtFile = target / "build.sbt"
    val projectScalaFile = target / "project.scala"
    
    val buildScContent = if os.exists(buildScFile) then os.read(buildScFile) else ""
    val buildSbtContent = if os.exists(buildSbtFile) then os.read(buildSbtFile) else ""
    val projectScalaContent = if os.exists(projectScalaFile) then os.read(projectScalaFile) else ""
    
    val combinedBuildContent = buildScContent + "\n" + buildSbtContent + "\n" + projectScalaContent

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
          val scalaVerRegex = """(?:def\s+scalaVersion\s*=\s*"|scalaVersion\s*:=\s*")([^"]+)"""".r
          scalaVerRegex.findFirstMatchIn(combinedBuildContent) match
            case Some(m) => m.group(1)
            case None => f.defaultValue

        // 3. Cross Version Compilation
        case "cross-version" =>
          val hasCross = combinedBuildContent.contains("CrossScalaModule") || 
                         combinedBuildContent.contains("crossScalaVersions") ||
                         combinedBuildContent.contains("Cross[AppModule]")
          if hasCross then "yes" else "no"

        // 4. Scripting Tool
        case "scripts" =>
          if os.exists(projectScalaFile) && !os.exists(buildScFile) && !os.exists(buildSbtFile) then
            // If it's scala-cli build tool, scripts is none
            "none"
          else if os.exists(projectScalaFile) then
            "scala-cli"
          else
            "none"

        // 5. GitHub Flow
        case "github-flow" =>
          if os.exists(target / ".github" / "workflows" / "ci.yml") then "yes" else "no"

        // 6. Ecosystem
        case "ecosystem" =>
          if combinedBuildContent.contains("cats-core") then "typelevel"
          else if combinedBuildContent.contains("zio") then "zio"
          else "none"

        // 7. Web Server
        case "web-server" =>
          val hasWebServer = combinedBuildContent.contains("http4s-ember-server") || 
                             combinedBuildContent.contains("zio-http")
          if hasWebServer then "yes" else "no"

        // 8. Web Client
        case "web-client" =>
          val hasWebClient = combinedBuildContent.contains("http4s-ember-client") || 
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
          if combinedBuildContent.contains("aws-lambda-java-core") then "yes" else "no"

        // 11. Testing Framework
        case "test-tools" =>
          if combinedBuildContent.contains("munit") then "munit+shapeless"
          else if combinedBuildContent.contains("zio-test") then "zio-test"
          else "none"

        // 12. Stainless
        case "stainless" =>
          if combinedBuildContent.contains("stainless-compiler-plugin") then "yes" else "no"

        // 13. Stryker
        case "stryker" =>
          if os.exists(target / "stryker4s.conf") then "yes" else "no"

        // 14. JMH Performance Testing
        case "performance-testing" =>
          if combinedBuildContent.contains("jmh-core") then "yes" else "no"

        // 15. Formatting
        case "formatting" =>
          if os.exists(target / ".scalafmt.conf") then "yes" else "no"

        // 16. Linting
        case "linting" =>
          if os.exists(target / ".scalafix.conf") then "yes" else "no"

        // 17. Optics (Monocle)
        case "optics" =>
          if combinedBuildContent.contains("monocle-core") then "yes" else "no"

        // 18. DTO Mapping (Chimney)
        case "dto-mapping" =>
          if combinedBuildContent.contains("chimney") then "yes" else "no"

        // 19. API Docs (Tapir)
        case "api-docs" =>
          if combinedBuildContent.contains("tapir-core") then "yes" else "no"

        case _ => f.defaultValue

      f.copy(defaultValue = detectedDefault)
    }

  def fetchLatestStableVersion(group: String, artifact: String): Option[String] =
    val groupPath = group.replace('.', '/')
    val url = s"https://repo1.maven.org/maven2/$groupPath/$artifact/maven-metadata.xml"
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
        ReleaseRegex.findFirstMatchIn(xml).map(_.group(1))
          .orElse(LatestRegex.findFirstMatchIn(xml).map(_.group(1)))
    catch
      case _: Exception => None

  def resolveLatestVersion(dep: String, scalaVer: String): String =
    val isScalaDep = dep.contains("::")
    val parts = if isScalaDep then dep.split("::") else dep.split(":")
    if parts.length >= 2 then
      val group = parts(0)
      val rest = parts(1).split(":")
      val artifactName = rest(0).stripPrefix(":")
      val defaultVer = if rest.length > 1 then rest.last else "latest"
      
      val scalaSuffix = if isScalaDep then
        if scalaVer.startsWith("3") then "_3" else "_2.13"
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
    else
      dep

  // Retrieve dependencies and plugins based on choices
  def getDependenciesAndPlugins(answers: Map[String, String], scalaVer: String): (List[String], List[String], List[String]) =
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
    val hasWebServer = answers.getOrElse("web-server", "no").toLowerCase.startsWith("y")
    if hasWebServer then
      if isTypelevel then
        deps = deps :+ "org.http4s::http4s-ember-server:0.23.27"
        deps = deps :+ "org.http4s::http4s-dsl:0.23.27"
      else if isZIO then
        deps = deps :+ "dev.zio::zio-http:3.0.0-RC6"

    // 3. Web Client
    val hasWebClient = answers.getOrElse("web-client", "no").toLowerCase.startsWith("y")
    if hasWebClient then
      if isTypelevel then
        deps = deps :+ "org.http4s::http4s-ember-client:0.23.27"
      else if isZIO then
        deps = deps :+ "com.softwaremill.sttp.client4::zio:4.0.0-RC1"
      else
        deps = deps :+ "com.softwaremill.sttp.client4::core:4.0.0-RC1"

    // 4. Database Access
    val hasDb = answers.getOrElse("db-access", "no").toLowerCase.startsWith("y")
    if hasDb then
      if isTypelevel then
        deps = deps :+ "org.tpolecat::doobie-core:1.0.0-RC5"
        deps = deps :+ "org.tpolecat::doobie-hikari:1.0.0-RC5"
      else if isZIO then
        deps = deps :+ "io.getquill::quill-jdbc-zio:4.8.4"
      else
        deps = deps :+ "org.postgresql:postgresql:42.7.3"

    // 5. Serverless Deployment
    val hasServerless = answers.getOrElse("serverless-run", "no").toLowerCase.startsWith("y")
    if hasServerless then
      deps = deps :+ "com.amazonaws:aws-lambda-java-core:1.2.3"
      deps = deps :+ "com.amazonaws:aws-lambda-java-events:3.11.4"

    // 6. Testing Framework
    val testTools = answers.getOrElse("test-tools", "munit+shapeless").toLowerCase
    if testTools.contains("munit") then
      testDeps = testDeps :+ "org.scalameta::munit:1.0.0"
    if testTools.contains("shapeless") then
      testDeps = testDeps :+ "org.typelevel::shapeless3-deriving:3.3.0"
    if isZIO || testTools.contains("zio") then
      testDeps = testDeps :+ "dev.zio::zio-test:2.0.21"
      testDeps = testDeps :+ "dev.zio::zio-test-sbt:2.0.21"

    // 7. Stainless Formal Verification
    val hasStainless = answers.getOrElse("stainless", "no").toLowerCase.startsWith("y")
    if hasStainless then
      plugins = plugins :+ "ch.epfl.lara::stainless-compiler-plugin:0.9.8.1"

    // 8. JMH Performance Testing
    val hasJmh = answers.getOrElse("performance-testing", "no").toLowerCase.startsWith("y")
    if hasJmh then
      deps = deps :+ "org.openjdk.jmh:jmh-core:1.37"

    // 9. Optics (Monocle)
    val hasOptics = answers.getOrElse("optics", "no").toLowerCase.startsWith("y")
    if hasOptics then
      deps = deps :+ "dev.optics::monocle-core:3.2.0"

    // 10. DTO Mapping (Chimney)
    val hasDto = answers.getOrElse("dto-mapping", "no").toLowerCase.startsWith("y")
    if hasDto then
      deps = deps :+ "io.scalaland::chimney:0.8.5"

    // 11. API Docs (Tapir)
    val hasApiDocs = answers.getOrElse("api-docs", "no").toLowerCase.startsWith("y")
    if hasApiDocs then
      deps = deps :+ "com.softwaremill.sttp.tapir::tapir-core:1.10.0"

    println("\nResolving latest library versions from Maven Central...")
    val resolvedDeps = deps.map(dep => resolveLatestVersion(dep, scalaVer))
    val resolvedTestDeps = testDeps.map(dep => resolveLatestVersion(dep, scalaVer))
    val resolvedPlugins = plugins.map(plugin => resolveLatestVersion(plugin, scalaVer))

    (resolvedDeps, resolvedTestDeps, resolvedPlugins)

  def setupStructure(target: os.Path, answers: Map[String, String]): Unit =
    os.makeDir.all(target / "app" / "src")
    os.makeDir.all(target / "app" / "test" / "src")

    // Write .gitignore if missing
    val gitignore = target / ".gitignore"
    if !os.exists(gitignore) then
      os.write(gitignore, "out/\n.bsp/\n.metals/\n.vscode/\n.idea/\n.DS_Store\n")

    // Write .scalafmt.conf if enabled and missing
    if answers.getOrElse("formatting", "no").toLowerCase == "yes" then
      val scalafmt = target / ".scalafmt.conf"
      if !os.exists(scalafmt) then
        os.write(scalafmt, "version = \"3.8.1\"\nrunner.dialect = scala3\n")

    // Write Stryker4s config if enabled and missing
    if answers.getOrElse("stryker", "no").toLowerCase == "yes" then
      val strykerConf = target / "stryker4s.conf"
      if !os.exists(strykerConf) then
        os.write(strykerConf, "stryker4s {\n  mutate: [ \"app/src/**/*.scala\" ]\n}\n")

    // Write .scalafix.conf if enabled and missing
    if answers.getOrElse("linting", "no").toLowerCase == "yes" then
      val scalafixConf = target / ".scalafix.conf"
      if !os.exists(scalafixConf) then
        os.write(scalafixConf, """rules = [
                                 |  OrganizeImports,
                                 |  DisableSyntax,
                                 |  LeakingImplicitClassVal,
                                 |  NoValInForComprehension
                                 |]
                                 |""".stripMargin)

    // Setup GitHub Flow CI Workflow if enabled
    if answers.getOrElse("github-flow", "no").toLowerCase == "yes" then
      val workflowDir = target / ".github" / "workflows"
      os.makeDir.all(workflowDir)
      val ciFile = workflowDir / "ci.yml"
      if !os.exists(ciFile) then
        val buildTool = answers.getOrElse("build-tool", "mill").toLowerCase
        val testCmd = if buildTool == "sbt" then "sbt test"
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

    // Write project-local .agents/mcp_config.json if the launcher script exists
    val localLauncher = os.home / ".local" / "bin" / "scalasemantic-mcp.sh"
    if os.exists(localLauncher) then
      val agentsDir = target / ".agents"
      os.makeDir.all(agentsDir)
      val mcpConfig = agentsDir / "mcp_config.json"
      val configContent =
        s"""{
           |  "mcpServers": {
           |    "scala-semantic": {
           |      "command": "${localLauncher.toString}",
           |      "args": ["${target.toString}"]
           |    }
           |  }
           |}
           |""".stripMargin
      os.write.over(mcpConfig, configContent)
      println("✓ Configured local scala-semantic MCP server (.agents/mcp_config.json)")

  def updateBuildSc(
    buildFile: os.Path,
    projectName: String,
    scalaVer: String,
    answers: Map[String, String],
    deps: List[String],
    testDeps: List[String],
    plugins: List[String]
  ): Unit =
    val crossComp = answers.getOrElse("cross-version", "no").toLowerCase == "yes"
    
    val template = if crossComp then
      s"""import mill._, scalalib._
         |
         |val scala3 = "$scalaVer"
         |val scala213 = "2.13.12"
         |
         |object app extends Cross[AppModule](scala3, scala213)
         |trait AppModule extends CrossScalaModule {
         |  def scalacOptions = Seq("-Ysemanticdb")
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
         |  def scalacOptions = Seq("-Ysemanticdb")
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

    if !os.exists(buildFile) then
      os.write(buildFile, template)
    else
      val content = os.read(buildFile)
      val hasCrossModule = content.contains("CrossScalaModule")
      if hasCrossModule != crossComp then
        os.write.over(buildFile, template)
    
    var content = os.read(buildFile)
    
    if !crossComp then
      val scalaVerRegex = """def scalaVersion\s*=\s*"[^"]*"""".r
      content = scalaVerRegex.replaceFirstIn(content, s"""def scalaVersion = "$scalaVer"""")

    if !content.contains("scalacOptions") then
      if content.contains("extends ScalaModule") then
        content = content.replace("extends ScalaModule {", "extends ScalaModule {\n  def scalacOptions = Seq(\"-Ysemanticdb\")")
      else if content.contains("extends CrossScalaModule") then
        content = content.replace("extends CrossScalaModule {", "extends CrossScalaModule {\n  def scalacOptions = Seq(\"-Ysemanticdb\")")

    def addDepToContent(section: String, dep: String): Unit =
      val depPart = dep.split("::").head
      if !content.contains(depPart) then
        val startMarker = s"// [$section-start]"
        if content.contains(startMarker) then
          content = content.replace(startMarker, s"$startMarker\n    ivy\"$dep\",")
          println(s"✓ Added dependency to build.sc: $dep")

    deps.foreach(dep => addDepToContent("dependencies", dep))
    testDeps.foreach(dep => addDepToContent("test-dependencies", dep))
    plugins.foreach(plugin => addDepToContent("plugins", plugin))

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
    val crossComp = answers.getOrElse("cross-version", "no").toLowerCase == "yes"
    val scalaVersionsStr = if crossComp then s"""Seq("$scalaVer", "2.13.12")""" else s"""Seq("$scalaVer")"""
    
    val template =
      s"""name := "$projectName"
         |version := "0.1.0-SNAPSHOT"
         |
         |scalaVersion := "$scalaVer"
         |crossScalaVersions := $scalaVersionsStr
         |
         |scalacOptions ++= Seq("-Ysemanticdb")
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

    if plugins.nonEmpty then
      val pluginsSbt = sbtFile / os.up / "project" / "plugins.sbt"
      var pluginsContent = if os.exists(pluginsSbt) then os.read(pluginsSbt) else ""
      plugins.foreach { plugin =>
        val pluginPart = plugin.split("::").head
        if !pluginsContent.contains(pluginPart) then
          val sbtPlugin = convertToSbtPlugin(plugin)
          pluginsContent += s"\naddSbtPlugin($sbtPlugin)"
          println(s"✓ Added plugin to project/plugins.sbt: $sbtPlugin")
      }
      os.write.over(pluginsSbt, pluginsContent)

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
      else
        s""""$dep""""

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
      "//> using options -Ysemanticdb"
    )

    deps.foreach { dep =>
      lines = lines :+ s"//> using dep $dep"
    }
    testDeps.foreach { dep =>
      lines = lines :+ s"//> using dep --test $dep"
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
