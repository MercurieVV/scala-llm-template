import stainless.lang.*
object L { def g(x: BigInt): BigInt = { require(x > 0); x } ensuring (r => r > 0) }
