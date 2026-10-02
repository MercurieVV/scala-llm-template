#!/bin/sh
echo 'x.Caps'
echo "  - long$(printf 'L%.0s' $(seq 1 150)) 1ms"
i=1
while [ "$i" -le 25 ]; do echo "  - case number $i 1ms"; i=$((i + 1)); done
exit 1
