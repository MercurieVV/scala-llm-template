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
      .withMinSuccessfulTests(StackFixtures.stacks.size)
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
      crossVersion: String
  ):
    def label: String =
      "build-tool=" + buildTool + " test-tools=" + testTools

    def answers: Map[String, String] = Map(
      "build-tool" -> buildTool,
      "test-tools" -> testTools,
      "cross-version" -> crossVersion,
      "scala-version" -> "3.8.4",
      "ecosystem" -> "none",
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
      "stainless" -> "no",
      "performance-testing" -> "no",
      "optics" -> "no",
      "dto-mapping" -> "no"
    )

  private object StackFixtures:
    val stacks: List[Stack] = List(
      Stack("mill", "munit+shapeless", "no"),
      Stack("sbt", "munit+shapeless", "no"),
      Stack("scala-cli", "munit+shapeless", "no")
    )

  private def stackGen: Gen[Stack] = Gen.oneOf(StackFixtures.stacks)

  private def runSetup(dir: os.Path, stack: Stack): os.CommandResult =
    val answersJson =
      ujson.Obj.from(stack.answers.map((k, v) => k -> ujson.Str(v))).render()
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
      val dir = itTestsRoot / (stack.buildTool + "-" + runId)
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

        true
      finally if os.exists(dir) then os.remove.all(dir)
    }
  }
