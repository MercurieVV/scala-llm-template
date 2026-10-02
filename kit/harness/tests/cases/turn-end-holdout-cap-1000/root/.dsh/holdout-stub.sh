#!/bin/sh
echo 'x.Big'
i=1
while [ "$i" -le 1100 ]; do echo "  - n$i 1ms"; i=$((i + 1)); done
exit 1
