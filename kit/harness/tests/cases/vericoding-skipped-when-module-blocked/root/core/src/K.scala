import stainless.lang.*
object K {
  def f(x: BigInt): BigInt = {
    require(x >= 0)
    x + 1
  } ensuring (r => r > x)
}
