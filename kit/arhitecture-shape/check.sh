#!/bin/sh
# =============================================================================
# check.sh — proves that the vendored `AllowedShape` rule still discriminates.
#
# The rule is deliberately not published (Vendored, not published — L2), so the
# only proof that a vendored copy still catches what it claims is this script:
# it compiles the rule, compiles two fixtures with SemanticDB, runs the real
# scalafix CLI over both and asserts the diagnostics it measures.
#
#   fixtures/violating/Example.scala  must produce a disallowedType diagnostic
#                                     for an importee AND one for an object
#                                     referenced as a term, plus a
#                                     disallowedConstruct diagnostic
#   fixtures/clean/Example.scala      must produce none, while declaring its own
#                                     `object` — the own-package prefix in the
#                                     allowlist is what keeps a module's own
#                                     definitions out of the report (the
#                                     convention every real consumer follows:
#                                     skreeep2's Mill helper appends it as
#                                     `allowedTypes() :+ ownPackagePrefix`)
#
# The type half of the rule is a `SemanticRule`: every type diagnostic is
# guarded by `t.symbol.value.nonEmpty`. Without SemanticDB the type half is
# silent, so this script compiles both fixtures with SemanticDB and puts the
# compiled output (which carries META-INF/semanticdb) on the CLI classpath —
# the same way a build tool passes `semanticDbData()`. It also asserts the
# semanticdb file exists, so a silent fall-back cannot be mistaken for a pass.
#
# POSIX sh only: no build tool, no Scala build file, nothing added to the
# adopting project. External requirements: `scala-cli` (compiler driver) and
# `cs` (coursier launcher for the scalafix CLI).
#
# Usage:
#   sh check.sh                       # the defaults below
#   sh check.sh "<allowed types>" "<disallowed constructs>"
#   ALLOWED_TYPES="..." DISALLOWED_CONSTRUCTS="..." sh check.sh
#
#   ALLOWED_TYPES         space-separated symbol prefixes/types (a symbol is
#                         allowed when it starts with one of these strings).
#                         The default is the minimal stdlib set plus `example/`,
#                         the fixture's own package prefix — appending the
#                         consumer's own package prefix is the convention every
#                         real consumer follows, and without it the rule reports
#                         a module's own `object Foo` as a term reference.
#   DISALLOWED_CONSTRUCTS space-separated scalameta node kind names (*Impl
#                         stripped), e.g. TermIf TermMatch DefnVar
#   ALLOWED_SHAPE_WORKDIR optional directory for intermediate output; by
#                         default a temporary directory is created and removed
# =============================================================================
set -eu

SCALA_VERSION=3.8.4
SCALAFIX_VERSION=0.14.7
SCALAFIX_RULES_ARTIFACT="ch.epfl.scala:scalafix-rules_${SCALA_VERSION}:${SCALAFIX_VERSION}"
SCALAFIX_CLI_ARTIFACT="ch.epfl.scala:scalafix-cli_${SCALA_VERSION}:${SCALAFIX_VERSION}"
SCALAFIX_CLI_MAIN=scalafix.cli.Cli

# Per-mechanism counts measured against the two committed fixtures (README,
# "what this check measures"), printed by every run and asserted below: the
# violating fixture raises one importee diagnostic (`import java.time.Instant`),
# one object-valued-term diagnostic (`scala.util.Random`, a genuine object
# symbol) and one construct diagnostic (`if`), and no plain Type.Name
# reference diagnostic. A change here means the rule, the fixture, or the
# compiler/semanticdb behaviour moved — never widen the allowlist to make a
# number go away (R-10).
EXPECT_VIOLATING_TYPE_REFS=0
EXPECT_VIOLATING_IMPORTEES=1
EXPECT_VIOLATING_OBJECT_TERMS=1
EXPECT_VIOLATING_CONSTRUCTS=1

# The default allowlist is the minimal stdlib set plus `example/`, this kit's
# fixture package. Appending the consumer's own package prefix is the convention
# every real consumer follows — skreeep2's Mill helper is
# `allowedTypes() :+ ownPackagePrefix` (buildKit/ArchitectureShapeModule.mill:56)
# — because a module's own `object Foo` is a term reference like any other and
# is otherwise reported. Overridable like the other defaults.
DEFAULT_ALLOWED_TYPES='scala/Predef.String scala/Int scala/Boolean scala/Unit scala/Any example/'
DEFAULT_DISALLOWED_CONSTRUCTS='TermIf'

# ---------------------------------------------------------------- locations --
kit_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
allowed_types=${ALLOWED_TYPES:-$DEFAULT_ALLOWED_TYPES}
disallowed_constructs=${DISALLOWED_CONSTRUCTS:-$DEFAULT_DISALLOWED_CONSTRUCTS}
if [ $# -gt 0 ]; then allowed_types=$1; fi
if [ $# -gt 1 ]; then disallowed_constructs=$2; fi

work_dir=${ALLOWED_SHAPE_WORKDIR:-}
own_work_dir=no
if [ -z "$work_dir" ]; then
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/allowed-shape-check.XXXXXX") ||
    { echo "check.sh: cannot create a temporary directory; set ALLOWED_SHAPE_WORKDIR=<dir>" >&2; exit 2; }
  own_work_dir=yes
else
  mkdir -p "$work_dir"
fi
cleanup() { if [ "$own_work_dir" = yes ] && [ -n "$work_dir" ]; then rm -rf "$work_dir"; fi; }
trap cleanup 0
trap 'exit 1' 1 2 3 15

fail() { echo "check.sh: $1" >&2; exit 1; }

command -v scala-cli >/dev/null 2>&1 || fail "'scala-cli' is not on PATH (needed to compile the rule and the fixtures)"
command -v cs >/dev/null 2>&1 || fail "'cs' (coursier) is not on PATH (needed to launch the scalafix CLI)"

echo "allowed-shape check: $kit_dir"
echo "  rule + fixtures compiled with scala-cli $SCALA_VERSION, scalafix CLI $SCALAFIX_VERSION"
echo "  allowedTypes         = [$allowed_types]"
echo "  disallowedConstructs = [$disallowed_constructs]"
echo "  work dir             = $work_dir"
echo

# ------------------------------------------------------- the rule's config --
config="$work_dir/allowed-shape.conf"
{
  echo 'AllowedShape {'
  echo '  allowedTypes = ['
  for t in $allowed_types; do echo "    \"$t\""; done
  echo '  ]'
  echo '  disallowedConstructs = ['
  for c in $disallowed_constructs; do echo "    \"$c\""; done
  echo '  ]'
  echo '}'
} > "$config"

# ------------------------------------------------------- compile the rule ---
# The rule is compiled from the vendored file itself, against the exact
# scalafix-rules artifact the rule's source targets. `--workspace` keeps every
# by-product out of the kit directory; `--server=false` keeps the compile
# non-interactive (no Bloop daemon).
rm -rf "$work_dir/rule-classes"
if ! scala-cli compile "$kit_dir/AllowedShape.scala" \
    --server=false --scala "$SCALA_VERSION" --dep "$SCALAFIX_RULES_ARTIFACT" \
    --workspace "$work_dir/ws-rule" -d "$work_dir/rule-classes" \
    > "$work_dir/compile-rule.log" 2>&1; then
  echo "check.sh: the rule did not compile against $SCALAFIX_RULES_ARTIFACT" >&2
  cat "$work_dir/compile-rule.log" >&2
  exit 1
fi

# The tool classpath is the compiled rule plus its registration: the
# META-INF/services/scalafix.v1.Rule file that lets `--rules AllowedShape`
# resolve to the rule class. Drop the registration and scalafix answers
# "Unknown rule 'AllowedShape'" — which is why it is asserted by this run.
tool_classes="$work_dir/tool-classes"
rm -rf "$tool_classes"
mkdir -p "$tool_classes"
cp -R "$work_dir/rule-classes/." "$tool_classes/"
[ -f "$kit_dir/META-INF/services/scalafix.v1.Rule" ] ||
  fail "the rule registration is missing: $kit_dir/META-INF/services/scalafix.v1.Rule"
cp -R "$kit_dir/META-INF" "$tool_classes/"

# --------------------------------------------------- run both fixtures ------
measured_violating_type_refs=0
measured_violating_importees=0
measured_violating_object_terms=0
measured_violating_constructs=0
measured_clean_type_refs=0
measured_clean_importees=0
measured_clean_object_terms=0
measured_clean_constructs=0

for name in violating clean; do
  fixture="$kit_dir/fixtures/$name/Example.scala"
  classes="$work_dir/classes-$name"
  diagnostics="$work_dir/diagnostics-$name.txt"

  echo "--- $name fixture: $fixture"
  if [ ! -f "$fixture" ]; then
    fail "fixture missing: $fixture (the check is only meaningful with both fixtures)"
  fi

  rm -rf "$classes" "$work_dir/ws-$name"
  if ! scala-cli compile "$fixture" \
      --server=false --scala "$SCALA_VERSION" \
      --semanticdb --semanticdb-sourceroot "$kit_dir" \
      --workspace "$work_dir/ws-$name" -d "$classes" \
      > "$work_dir/compile-$name.log" 2>&1; then
    echo "check.sh: the $name fixture did not compile" >&2
    cat "$work_dir/compile-$name.log" >&2
    exit 1
  fi

  # SemanticDB is what the type half reads; without it the run below would
  # report "SemanticDB not found" and measure nothing about the allowlist. The
  # fixture's file name is part of this path: rename the file and update it.
  if [ ! -f "$classes/META-INF/semanticdb/fixtures/$name/Example.scala.semanticdb" ]; then
    fail "no SemanticDB was produced for the $name fixture ($classes/META-INF/semanticdb) — the type half of the rule cannot run"
  fi

  if cs launch "$SCALAFIX_CLI_ARTIFACT" --main-class "$SCALAFIX_CLI_MAIN" -- \
      --tool-classpath "$tool_classes" \
      --rules AllowedShape \
      --config "$config" \
      --classpath "$classes" \
      --sourceroot "$kit_dir" \
      --check \
      "$fixture" > "$diagnostics" 2>&1; then
    cli_status=0
  else
    cli_status=$?
  fi

  echo "  scalafix exit status: $cli_status"
  cat "$diagnostics"

  # Attribution per mechanism, read off the diagnostic messages: the importee
  # check says "import of …", the object-valued-term check says "…, referenced
  # as a term", a plain Type.Name reference says neither, and the construct
  # check carries its own lint ID — so no count is reported without saying which
  # mechanism produced it.
  type_total=$(grep -c '\[AllowedShape\.disallowedType\]' "$diagnostics" || true)
  importees=$(grep -c '\[AllowedShape\.disallowedType\] import of ' "$diagnostics" || true)
  object_terms=$(grep -c 'referenced as a term' "$diagnostics" || true)
  type_refs=$((type_total - importees - object_terms))
  constructs=$(grep -c '\[AllowedShape\.disallowedConstruct\]' "$diagnostics" || true)

  echo "  measured: type references $type_refs, importees $importees, object-valued terms $object_terms, constructs $constructs"

  if [ "$name" = violating ]; then
    measured_violating_type_refs=$type_refs
    measured_violating_importees=$importees
    measured_violating_object_terms=$object_terms
    measured_violating_constructs=$constructs
    [ "$importees" -ge 1 ] ||
      fail "the violating fixture produced no importee diagnostic: the allowlist half did not run (semanticdb? rule config?)"
    [ "$object_terms" -ge 1 ] ||
      fail "the violating fixture produced no object-valued-term diagnostic: a disallowed type reached as a term was not caught"
    [ "$constructs" -ge 1 ] ||
      fail "the violating fixture produced no disallowedConstruct diagnostic: the denylist half did not run"
    [ "$type_refs" -eq "$EXPECT_VIOLATING_TYPE_REFS" ] &&
      [ "$importees" -eq "$EXPECT_VIOLATING_IMPORTEES" ] &&
      [ "$object_terms" -eq "$EXPECT_VIOLATING_OBJECT_TERMS" ] &&
      [ "$constructs" -eq "$EXPECT_VIOLATING_CONSTRUCTS" ] ||
      fail "the violating fixture produced type references $type_refs, importees $importees, object-valued terms $object_terms, constructs $constructs; expected $EXPECT_VIOLATING_TYPE_REFS, $EXPECT_VIOLATING_IMPORTEES, $EXPECT_VIOLATING_OBJECT_TERMS and $EXPECT_VIOLATING_CONSTRUCTS. Re-measure them deliberately if the rule, the fixtures, the allowlist arguments or the toolchain moved — never widen the allowlist or lower an expectation to make a run pass (R-10)"
  else
    measured_clean_type_refs=$type_refs
    measured_clean_importees=$importees
    measured_clean_object_terms=$object_terms
    measured_clean_constructs=$constructs
    [ "$type_total" -eq 0 ] && [ "$constructs" -eq 0 ] ||
      fail "the clean fixture produced type references $type_refs, importees $importees, object-valued terms $object_terms, constructs $constructs: the check does not discriminate"
  fi
  echo
done

echo "violating: $((measured_violating_type_refs + measured_violating_importees + measured_violating_object_terms + measured_violating_constructs)) diagnostics [type references $measured_violating_type_refs, importees $measured_violating_importees, object-valued terms $measured_violating_object_terms, constructs $measured_violating_constructs]"
echo "clean: $((measured_clean_type_refs + measured_clean_importees + measured_clean_object_terms + measured_clean_constructs)) diagnostics [type references $measured_clean_type_refs, importees $measured_clean_importees, object-valued terms $measured_clean_object_terms, constructs $measured_clean_constructs]"
echo "OK"
