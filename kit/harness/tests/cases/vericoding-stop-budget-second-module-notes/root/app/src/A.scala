import stainless.lang.*
object A { def g(x: BigInt): BigInt = { require(x > 0); x } ensuring (r => r > 0) }
