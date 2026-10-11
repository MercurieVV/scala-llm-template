object F:
  def small(x: Int): Int =
    if x > 0 && x < 5 then 1
    else
      x match
        case 1 => 2
        case _ => 3

  def big(x: Int): Int =
    if x == 1 then 1
    else if x == 2 then 2
    else if x == 3 then 3
    else if x == 4 then 4
    else if x == 5 then 5
    else if x == 6 then 6
    else if x == 7 then 7
    else if x == 8 then 8
    else if x == 9 then 9
    else if x == 10 then 10
    else if x == 11 then 11
    else 0

  def outer(x: Int): Int =
    // a comment line is not SLOC
    def inner(y: Int): Int = if y > 0 then y else 0
    inner(x)
