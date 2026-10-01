#!/bin/sh
# Records each module it ran, then fails for the module(s) named in .dsh/te-red (one id per line).
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s\n' "$1" >> "$d/te-calls.log"
if [ -f "$d/te-red" ] && grep -qx "$1" "$d/te-red"; then
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
fi
printf 'com.x.PhraseProps\n+ passes 1ms\nTotal 1, Failed 0, Passed 1, Ignored 0, Cancelled 0\n'
exit 0
