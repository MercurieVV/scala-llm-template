import mill._, scalalib._

object app extends ScalaModule {
  def scalaVersion = "3.8.4"
  def scalacOptions = Seq("-Ysemanticdb")
  def ivyDeps = Agg(
    // [dependencies-start]
    ivy"org.typelevel::cats-core:2.10.0",
    // [dependencies-end]
  )

  def scalacPluginIvyDeps = Agg(
    // [plugins-start]
    ivy"ch.epfl.lara::stainless-compiler-plugin:0.9.8.1",
    // [plugins-end]
  )

  object test extends ScalaTests {
    def testFramework = "munit.Framework"
    def ivyDeps = Agg(
      // [test-dependencies-start]
    ivy"org.scalameta::munit::1.0.0",
      // [test-dependencies-end]
    )
  }
}
