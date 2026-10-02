#!/bin/sh
cat <<'XX'
x.LEAKassertplayerstopReleased42
  - { 1ms
  - t 1ms
  - assert(player.stop() == Released(42)) 1ms
  - stop releases device and more 1ms
  - exact name 1ms
XX
exit 1
