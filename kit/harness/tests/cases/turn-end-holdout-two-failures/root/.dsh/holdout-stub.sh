#!/bin/sh
cat <<'EOF'
com.github.mercurievv.skreeep2.holdout.PlaybackHoldout
  + gain then seek keeps position 12ms
  - stop releases device 4ms
  - a second failure 9ms

*************FAILURES**************
com.github.mercurievv.skreeep2.holdout.PlaybackHoldout
  - stop releases device 4ms
  Expected true but got false (PlaybackHoldout.scala:41)

Total 3, Failed 2, Passed 1, Ignored 0, Cancelled 0
EOF
exit 1
