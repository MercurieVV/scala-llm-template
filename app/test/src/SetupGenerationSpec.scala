import org.scalacheck.Gen
import org.scalacheck.Prop

import scala.concurrent.duration._

/** End-to-end test: drives the real `Setup.scala` CLI (agent mode) against real
  * files under `out/it-tests/`, once to create a project for a given build-tool
  * stack and once more to update it in place. Verifies the files Setup.scala is
  * expected to produce, including the mill version pin.
  */
class SetupGenerationSpec extends munit.ScalaCheckSuite:
  override val munitTimeout: Duration = 10.minutes

  override def scalaCheckTestParameters =
    super.scalaCheckTestParameters
      .withMinSuccessfulTests(
        math.max(StackFixtures.stacks.size, featureCases.size)
      )
      .withMaxDiscardRatio(1)

  private val repoRoot: os.Path =
    try
      os.Path(
        os.proc("git", "rev-parse", "--show-toplevel").call().out.text().trim
      )
    catch case _: Exception => os.pwd

  private val itTestsRoot: os.Path = repoRoot / "out" / "it-tests"

  private case class Stack(
      buildTool: String,
      testTools: String,
      crossVersion: String,
      ecosystem: String,
      stainless: String
  ):
    def label: String =
      "build-tool=" + buildTool + " test-tools=" + testTools + " ecosystem=" + ecosystem + " stainless=" + stainless

    def answers: Map[String, String] = Map(
      "build-tool" -> buildTool,
      "test-tools" -> testTools,
      "cross-version" -> crossVersion,
      "scala-version" -> "3.8.4",
      "ecosystem" -> ecosystem,
      "scripts" -> "none",
      "github-flow" -> "no",
      "mcp-tools" -> "no",
      "mdoc" -> "no",
      "git-hooks" -> "no",
      "version-bump" -> "no",
      "stryker" -> "no",
      "web-server" -> "no",
      "web-client" -> "no",
      "db-access" -> "no",
      "serverless-run" -> "no",
      "api-docs" -> "no",
      "stainless" -> stainless,
      "performance-testing" -> "no",
      "optics" -> "no",
      "dto-mapping" -> "no"
    )

  private object StackFixtures:
    val stacks: List[Stack] = List(
      Stack("mill", "munit+shapeless", "no", "none", "no"),
      Stack("sbt", "munit+shapeless", "no", "none", "no"),
      Stack("scala-cli", "munit+shapeless", "no", "none", "no"),
      Stack("scala-cli", "munit+shapeless", "no", "typelevel", "no"),
      Stack("scala-cli", "munit+shapeless", "no", "none", "yes")
    )

  private def stackGen: Gen[Stack] = Gen.oneOf(StackFixtures.stacks)

  private def runSetupRaw(
      dir: os.Path,
      answers: Map[String, String]
  ): os.CommandResult =
    val answersJson =
      ujson.Obj.from(answers.map((k, v) => k -> ujson.Str(v))).render()
    os.proc(
      "scala-cli",
      "run",
      "Setup.scala",
      "--",
      "--agent",
      "--answers",
      answersJson,
      dir.toString
    ).call(
      cwd = repoRoot,
      check = false,
      stdout = os.Pipe,
      stderr = os.Pipe,
      mergeErrIntoOut = true
    )

  private def runSetup(dir: os.Path, stack: Stack): os.CommandResult =
    runSetupRaw(dir, stack.answers)

  private def expectedBuildFiles(stack: Stack): Map[String, Boolean] =
    Map(
      "build.sc" -> (stack.buildTool == "mill"),
      "build.sbt" -> (stack.buildTool == "sbt"),
      "project.scala" -> (stack.buildTool == "scala-cli")
    )

  property(
    "creates then updates a real project on disk for every build-tool stack"
  ) {
    Prop.forAllNoShrink(stackGen) { stack =>
      val runId = java.util.UUID.randomUUID().toString.take(8)
      val dir = itTestsRoot / (stack.buildTool + "-" + stack.ecosystem + "-" +
        stack.stainless + "-" + runId)
      try
        // Create
        val created = runSetup(dir, stack)
        assert(
          created.exitCode == 0,
          "create failed for " + stack.label + ":\n" + created.out.text()
        )
        assert(created.out.text().contains("Setup Completed Successfully"))

        val savedConfig = ujson
          .read(os.read(dir / ".agents" / "setup_config.json"))
          .obj
          .map((k, v) => k -> v.str)
          .toMap
        assertEquals(savedConfig.get("build-tool"), Some(stack.buildTool))
        assertEquals(savedConfig.get("ecosystem"), Some(stack.ecosystem))

        if stack.ecosystem == "typelevel" then
          val buildFileName = expectedBuildFiles(stack)
            .collectFirst { case (name, true) => name }
            .getOrElse("project.scala")
          val buildContent = os.read(dir / buildFileName)
          assert(
            buildContent.contains("cats-core"),
            "expected cats-core dependency for " + stack.label
          )

        expectedBuildFiles(stack).foreach { case (fileName, shouldExist) =>
          assertEquals(
            os.exists(dir / fileName),
            shouldExist,
            fileName + " presence mismatch for " + stack.label
          )
        }

        assertEquals(
          os.exists(dir / ".mill-version"),
          stack.buildTool == "mill",
          ".mill-version presence mismatch for " + stack.label
        )
        if stack.buildTool == "mill" then
          assert(os.read(dir / ".mill-version").trim.nonEmpty)

        assertEquals(
          os.exists(dir / "scripts" / "stainless-verify.sh"),
          stack.stainless == "yes",
          "scripts/stainless-verify.sh presence mismatch for " + stack.label
        )
        assertEquals(
          os.exists(dir / "stainless.conf"),
          stack.stainless == "yes",
          "stainless.conf presence mismatch for " + stack.label
        )
        if stack.stainless == "yes" then
          val verifyResult = os
            .proc("bash", (dir / "scripts" / "stainless-verify.sh").toString)
            .call(
              cwd = dir,
              check = false,
              stdout = os.Pipe,
              stderr = os.Pipe,
              mergeErrIntoOut = true
            )
          assertEquals(
            verifyResult.exitCode,
            0,
            "stainless-verify.sh should no-op (not fail) without the Stainless CLI installed: " + verifyResult.out
              .text()
          )

        assert(os.isDir(dir / "app" / "src"))
        assert(os.isDir(dir / "app" / "test" / "src"))
        assert(os.isDir(dir / ".git"))

        // Update: re-running on the same directory must detect the existing
        // project, not re-initialize it, and stay idempotent.
        val updated = runSetup(dir, stack)
        assert(
          updated.exitCode == 0,
          "update failed for " + stack.label + ":\n" + updated.out.text()
        )
        assert(updated.out.text().contains("Switching to update mode"))

        expectedBuildFiles(stack).foreach { case (fileName, shouldExist) =>
          assertEquals(
            os.exists(dir / fileName),
            shouldExist,
            fileName + " presence mismatch after update for " + stack.label
          )
        }
        assertEquals(
          os.exists(dir / "scripts" / "stainless-verify.sh"),
          stack.stainless == "yes",
          "scripts/stainless-verify.sh presence mismatch after update for " + stack.label
        )

        true
      finally if os.exists(dir) then os.remove.all(dir)
    }
  }

  /** Covers the remaining feature flags not exercised by the build-tool/
    * ecosystem/stainless matrix above: for each, asserts the expected
    * dependency lands in the generated build file and the expected section
    * lands in the generated docs (scala-rules.md, .cursorrules,
    * .agents/AGENTS.md, which must all be identical). Flags are batched into a
    * few real project generations rather than one process per flag, since their
    * effects on the build file/docs don't interact.
    */
  private val baselineAnswers: Map[String, String] = Map(
    "build-tool" -> "scala-cli",
    "scala-version" -> "3.8.4",
    "cross-version" -> "no",
    "scripts" -> "none",
    "github-flow" -> "no",
    "ecosystem" -> "none",
    "web-server" -> "no",
    "web-client" -> "no",
    "db-access" -> "no",
    "serverless-run" -> "no",
    "api-docs" -> "no",
    "test-tools" -> "munit+shapeless",
    "stainless" -> "no",
    "stryker" -> "no",
    "performance-testing" -> "no",
    "optics" -> "no",
    "dto-mapping" -> "no",
    "mcp-tools" -> "no",
    "mdoc" -> "no",
    "git-hooks" -> "no",
    "version-bump" -> "no"
  )

  private case class FeatureCase(
      label: String,
      overrides: Map[String, String],
      depNeedles: List[String],
      docNeedles: List[String],
      extraFiles: List[String]
  ):
    def answers: Map[String, String] = baselineAnswers ++ overrides

  private val featureCases: List[FeatureCase] = List(
    FeatureCase(
      "kitchen-sink",
      Map(
        "web-client" -> "yes",
        "db-access" -> "yes",
        "serverless-run" -> "yes",
        "performance-testing" -> "yes",
        "optics" -> "yes",
        "dto-mapping" -> "yes",
        "api-docs" -> "yes",
        "mcp-tools" -> "yes",
        "mdoc" -> "yes",
        "git-hooks" -> "yes",
        "version-bump" -> "yes",
        "stryker" -> "yes"
      ),
      depNeedles = List(
        "sttp.client4",
        "postgresql",
        "aws-lambda-java-core",
        "jmh-core",
        "monocle-core",
        "chimney",
        "tapir-core"
      ),
      docNeedles = List(
        "## 6. Web Client",
        "## 7. Database Access",
        "## 8. Serverless Deployment",
        "## 12. Performance & JMH Benchmarking",
        "## 14. Immutable Data Optics (Monocle)",
        "## 15. Data Transformation (Chimney)",
        "## 16. API Specifications (Tapir)",
        "## 18. ScalaSemantic MCP Rules",
        "## 11. Mutation Testing (Stryker)"
      ),
      extraFiles = List(
        "docs/index.md",
        "mdoc-docs/src/main/scala/DocsMain.scala",
        "scripts/version-bump.scala",
        "stryker4s.conf",
        "scripts/git-pre-commit.scala",
        "scripts/git-pre-push.scala"
      )
    ),
    FeatureCase(
      "web-server-typelevel",
      Map(
        "ecosystem" -> "typelevel",
        "web-server" -> "yes",
        "web-client" -> "yes"
      ),
      depNeedles = List(
        "cats-core",
        "http4s-ember-server",
        "http4s-dsl",
        "http4s-ember-client"
      ),
      docNeedles = List("## 5. Web Server", "Http4s Ember", "## 6. Web Client"),
      extraFiles = Nil
    ),
    FeatureCase(
      "zio-test-tools",
      Map("test-tools" -> "zio-test"),
      depNeedles = List("zio-test"),
      docNeedles = List("## 9. Testing Guidelines (ZIO Test)"),
      extraFiles = Nil
    )
  )

  private def featureCaseGen: Gen[FeatureCase] = Gen.oneOf(featureCases)

  property(
    "generates the expected library dependency and docs text for every feature flag"
  ) {
    Prop.forAllNoShrink(featureCaseGen) { featureCase =>
      val runId = java.util.UUID.randomUUID().toString.take(8)
      val dir = itTestsRoot / ("feature-" + featureCase.label + "-" + runId)
      try
        val created = runSetupRaw(dir, featureCase.answers)
        assert(
          created.exitCode == 0,
          "create failed for " + featureCase.label + ":\n" + created.out.text()
        )

        val buildContent = os.read(dir / "project.scala")
        featureCase.depNeedles.foreach { needle =>
          assert(
            buildContent.contains(needle),
            "expected dependency \"" + needle + "\" in project.scala for " + featureCase.label
          )
        }

        val rulesContent = os.read(dir / "scala-rules.md")
        val cursorContent = os.read(dir / ".cursorrules")
        val agentsContent = os.read(dir / ".agents" / "AGENTS.md")
        assertEquals(
          cursorContent,
          rulesContent,
          ".cursorrules should mirror scala-rules.md for " + featureCase.label
        )
        assertEquals(
          agentsContent,
          rulesContent,
          ".agents/AGENTS.md should mirror scala-rules.md for " + featureCase.label
        )
        featureCase.docNeedles.foreach { needle =>
          assert(
            rulesContent.contains(needle),
            "expected doc text \"" + needle + "\" in scala-rules.md for " + featureCase.label
          )
        }

        featureCase.extraFiles.foreach { relPath =>
          assert(
            os.exists(dir / os.RelPath(relPath)),
            "expected file \"" + relPath + "\" for " + featureCase.label
          )
        }

        true
      finally if os.exists(dir) then os.remove.all(dir)
    }
  }
