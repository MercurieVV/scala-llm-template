#!/bin/sh
cat <<'T'
Running Test Class com.x.PhraseProps
com.x.PhraseProps
+ passes 1ms
- strikes are strictly increasing 4ms

*************FAILURES**************
com.x.PhraseProps
- strikes are strictly increasing 4ms
 [0] Property test failed on try 3 with seed Seed.fromBase64("AAA=") and input List(Strike(0.0), Strike(0.0)) (modules/scalacheck/src/weaver/scalacheck/Checkers.scala:195)

 [1] assertion failed (PhraseProps.scala:12)

T
exit 1
