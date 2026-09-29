# Sourced: builds a PATH that is the current one minus every sha256 tool (shasum*, sha256sum), as a
# directory of symlinks, and prints it. The runner owns PATH for the gate invocation, so the no-hasher
# runs are made by this case's own scripts.
nb="$SCRATCH_ROOT/.git/nohashbin"   # inside .git: removed with the scratch root, never a git path
if [ ! -d "$nb" ]; then
  mkdir -p "$nb"
  _ifs=$IFS; IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=${f##*/}
      case "$b" in shasum*|sha256sum) continue ;; esac
      [ -x "$f" ] && [ ! -e "$nb/$b" ] && ln -s "$f" "$nb/$b"
    done
  done
  IFS=$_ifs
fi
printf '%s\n' "$nb"
