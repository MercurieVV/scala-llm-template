#!/bin/sh
# Test double for a generated guard installed WITHOUT --strict-edits: it allows everything.
# A bash write is classified in-repo and must never be handed to it, so this case can only
# pass while the delegation below carries reads only (F34).
cat >/dev/null
echo "ScalaSemantic guard: allowed"
exit 0
