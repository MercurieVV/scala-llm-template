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

  // Defined and grouped features
  val featuresList = List(
    // 1. Language & Compiler Core
    Feature("scala-version", "Core", "Scala Version", "Enter Scala version", "3.3.3"),
    Feature("cross-version", "Core", "Cross Version Compilation", "Enable cross version compilation?", "no"),
    Feature("build-tool", "Core", "Build Tool", "Primary build tool", "mill"),
    Feature("scripts", "Core", "Scripting Tool", "Scripting wrapper", "scala-cli"),
    Feature("github-flow", "Core", "GitHub Flow Integration", "Enable GitHub Flow (CI Workflow)?", "yes"),

    // 2. Ecosystem & Frameworks
    Feature("ecosystem", "Ecosystem", "Primary Ecosystem", "Ecosystem (typelevel, zio, none)", "typelevel",
      ivyDeps = List("org.typelevel::cats-core:2.10.0")),
    Feature("web-server", "Ecosystem", "Web Server", "Enable Web Server?", "no"),
    Feature("web-client", "Ecosystem", "Web Client", "Enable Web Client?", "no"),
    Feature("db-access", "Ecosystem", "Database Access", "Enable Database Access?", "no"),
    Feature("serverless-run", "Ecosystem", "Serverless Deployment", "Enable Serverless run?", "no"),

    // 3. Verification & Quality Assurance
    Feature("test-tools", "Quality Assurance", "Testing Framework", "Test tools (e.g. munit+shapeless)", "munit+shapeless",
      ivyDeps = List("org.scalameta::munit::1.0.0", "org.typelevel::shapeless3-deriving::3.3.0")),
    Feature("stainless", "Quality Assurance", "Stainless Verification", "Enable Stainless formal verification?", "yes",
      scalacPlugins = List("ch.epfl.lara::stainless-compiler-plugin:0.9.8.1")),
    Feature("stryker", "Quality Assurance", "Stryker Mutation Testing", "Enable Stryker mutation testing?", "yes"),
    Feature("performance-testing", "Quality Assurance", "JMH Performance Testing", "Enable JMH performance testing?", "no"),

    // 4. Proposed Utilities (Additions)
    Feature("formatting", "Developer Tooling", "Scalafmt Formatting", "Enable Scalafmt configuration?", "yes"),
    Feature("linting", "Developer Tooling", "Scalafix Linter", "Enable Scalafix?", "yes"),
    Feature("optics", "Data Utilities", "Monocle Optics", "Enable Monocle (lenses/optics for immutable structures)?", "no",
      ivyDeps = List("dev.optics::monocle-core::3.2.0")),
    Feature("dto-mapping", "Data Utilities", "Chimney DTO Mapping", "Enable Chimney (type-safe data transformation)?", "no",
      ivyDeps = List("io.scalaland::chimney::0.8.5")),
    Feature("api-docs", "Ecosystem", "Tapir API Documentation", "Enable Tapir (declarative endpoints)?", "no",
      ivyDeps = List("com.softwaremill.sttp.tapir::tapir-core::1.10.0"))
  )

  def main(args: Array[String]): Unit =
    println("=== Scala Project Setup & Update (Mill + Global Rules) ===")

    // Determine target directory
    val targetDir = args.headOption match
      case Some(".") | None => os.pwd
      case Some(path) => 
        val d = os.Path(path, os.pwd)
        if !os.exists(d) then os.makeDir.all(d)
        d

    val projectName = targetDir.last
    val buildFile = targetDir / "build.sc"
    val isExisting = os.exists(buildFile)

    if isExisting then
      println(s"Found existing Mill project in $targetDir. Switching to update mode.")
    else
      println(s"Initializing new Mill project in $targetDir...")

    // 1. Fetch/Update Master Rules in the SHARED folder
    updateMasterRules()

    // 2. Q&A Loop for Features (Grouped output)
    val answers = promptFeaturesGrouped(featuresList)

    // 3. Setup Project Structure
    setupStructure(targetDir, answers)

    // 4. Create/Update Build File (Mill build.sc)
    val selectedScalaVer = answers.getOrElse("scala-version", "3.3.3")
    updateBuildSc(buildFile, projectName, selectedScalaVer, answers, featuresList)

    // 5. Setup Git (Uncommitted changes)
    setupGit(targetDir)

    println(s"\n=== Setup Completed Successfully! ===")
    println(s"Project Location: $targetDir")
    println(s"Selected Scala Version: $selectedScalaVer")
    println("\nRules have been configured globally in the shared folder:")
    println(s"  $masterRulesFile")
    println("\nNo symlinks or rule files were created inside the project folder.")
    println("Run 'mill test' to verify and compile.")

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
    val p = os.proc("curl", "-fsSL", "--connect-timeout", "3", url).call()
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
          val response = readLine(s"  ${f.name} [${f.prompt}] (default: ${f.defaultValue}): ").trim
          val finalVal = if response.isEmpty then f.defaultValue else response
          answers = answers + (f.id -> finalVal)
        }
      }
    }
    answers

  def setupStructure(target: os.Path, answers: Map[String, String]): Unit =
    os.makeDir.all(target / "app" / "src")
    os.makeDir.all(target / "app" / "test" / "src")

    // Write .gitignore if missing
    val gitignore = target / ".gitignore"
    if !os.exists(gitignore) then
      os.write(gitignore, "out/\n.bsp/\n.metals/\n.vscode/\n.idea/\n.DS_Store\n")

    // Write .scalafmt.conf if enabled and missing
    if answers.getOrElse("formatting", "no") == "yes" then
      val scalafmt = target / ".scalafmt.conf"
      if !os.exists(scalafmt) then
        os.write(scalafmt, "version = \"3.8.1\"\nrunner.dialect = scala3\n")

    // Write Stryker4s config if enabled and missing
    if answers.getOrElse("stryker", "no") == "yes" then
      val strykerConf = target / "stryker4s.conf"
      if !os.exists(strykerConf) then
        os.write(strykerConf, "stryker4s {\n  mutate: [ \"app/src/**/*.scala\" ]\n}\n")

    // Setup GitHub Flow CI Workflow if enabled
    if answers.getOrElse("github-flow", "no") == "yes" then
      val workflowDir = target / ".github" / "workflows"
      os.makeDir.all(workflowDir)
      val ciFile = workflowDir / "ci.yml"
      if !os.exists(ciFile) then
        val ciContent = """name: CI
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
                          |      run: mill app.test
                          |""".stripMargin
        os.write(ciFile, ciContent)
        println("✓ Created GitHub CI workflow (.github/workflows/ci.yml)")

  def updateBuildSc(
    buildFile: os.Path,
    projectName: String,
    scalaVer: String,
    answers: Map[String, String],
    features: List[Feature]
  ): Unit =
    if !os.exists(buildFile) then
      val template = 
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
      os.write(buildFile, template)

    var content = os.read(buildFile)
    
    // Update Scala version
    val scalaVerRegex = """def scalaVersion\s*=\s*"[^"]*"""".r
    content = scalaVerRegex.replaceFirstIn(content, s"""def scalaVersion = "$scalaVer"""")

    // Ensure SemanticDB option is enabled by default
    if !content.contains("scalacOptions") then
      content = content.replace(
        s"""def scalaVersion = "$scalaVer"""",
        s"""def scalaVersion = "$scalaVer"\n  def scalacOptions = Seq("-Ysemanticdb")"""
      )

    // Idempotent dependency addition helper
    def addDep(section: String, dep: String): Unit =
      val depPart = dep.split("::").head
      if !content.contains(depPart) then
        val startMarker = s"// [$section-start]"
        if content.contains(startMarker) then
          content = content.replace(startMarker, s"$startMarker\n    ivy\"$dep\",")
          println(s"✓ Added dependency: $dep")

    features.foreach { f =>
      val response = answers.getOrElse(f.id, f.defaultValue).toLowerCase
      val enabled = response == "yes" || response == "y" || (f.id == "ecosystem" && response == "typelevel") || (f.id == "test-tools" && response == "munit+shapeless")

      if enabled then
        // Add dependencies
        f.ivyDeps.foreach { dep =>
          if dep.contains("munit") || dep.contains("shapeless") then
            addDep("test-dependencies", dep)
          else
            addDep("dependencies", dep)
        }
        // Add plugins
        f.scalacPlugins.foreach { plugin =>
          addDep("plugins", plugin)
        }
    }

    os.write.over(buildFile, content)

  def setupGit(target: os.Path): Unit =
    if !os.exists(target / ".git") then
      os.proc("git", "init").call(cwd = target)
    os.proc("git", "add", ".").call(cwd = target)
