import stainless.lang.*
object K {
  def f(x: BigInt): BigInt = {
    x + 1
  } ensuring (r => r > x)
}
