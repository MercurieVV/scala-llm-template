#!/bin/sh
# Test double whose verdict is the OPPOSITE of the in-repo fallback's: it allows anything,
# including the .scala read the fallback would deny. This case can only pass when the read
# decision really was delegated to the generated guard.
cat >/dev/null
echo "ScalaSemantic guard: allowed"
exit 0
