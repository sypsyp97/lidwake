#!/usr/bin/env bash
# Model-check the lidwake Controller protocol with TLC.
#
#   ./check.sh        all groups below
#   ./check.sh -v     also print the TLC error trace of every violation
#
# Groups (each property is checked in its own TLC run, so one violation
# does not hide another):
#   base        Lidwake.cfg (SPEC revision 5, UserRace = FALSE, journal always
#               readable): every property must hold
#   mutation    base + one seeded bug: the targeted property must be violated
#   limitation  base + UserRace = TRUE (SPEC 8 "Known limitation"):
#               NeverClobberUser and EventuallyRestored are expected to fail,
#               the other properties must hold
#   corrupt     base + Corruption = TRUE (journal.json can become unreadable):
#               the safety invariants and EventuallyNoUnwantedHold must hold;
#               NeverClobberUser and EventuallyRestored fail by design (an
#               unreadable journal is loaded as owned, so a user's own 1 can be
#               cleared); the old rule (corruptAsUnowned) must fail; the
#               recovery paths must be reachable; a corruption while a pmset
#               child is recorded (CorruptWithPending) is a known limitation
# Exit status is 0 only when every run gives its expected result.
set -u
cd "$(dirname "$0")"

JAR=${TLA_JAR:-$HOME/.local/share/tla/tla2tools.jar}
JAVA=${JAVA:-}
if [ -z "$JAVA" ]; then
  if [ -x /opt/homebrew/opt/openjdk/bin/java ]; then JAVA=/opt/homebrew/opt/openjdk/bin/java; else JAVA=java; fi
fi
VERBOSE=0
for a in "$@"; do
  case "$a" in
    -v) VERBOSE=1 ;;
    *) echo "usage: $0 [-v]" >&2; exit 2 ;;
  esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lidwake-tla.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
INVARIANTS="TypeOK NoOrphanHold AssertionIffHold"
PROPERTIES="NeverClobberUser EventuallyRestored EventuallyNoUnwantedHold"
status=0

# mkcfg FILE USERRACE MUTATION PROPERTY [CORRUPTION [CORRUPT_WITH_PENDING]]
mkcfg() {
  {
    echo "SPECIFICATION Spec"
    echo "CONSTANTS"
    echo "    S = 2"
    echo "    UserRace = $2"
    echo "    Mutation = \"$3\""
    echo "    Corruption = ${5:-FALSE}"
    echo "    CorruptWithPending = ${6:-FALSE}"
    case " $INVARIANTS NeverQuarantines RestoreNeverQuarantines " in
      *" $4 "*) echo "INVARIANTS $4" ;;
      *) echo "PROPERTIES $4" ;;
    esac
  } > "$1"
}

# run LABEL MODULE CFG EXPECT(pass|fail) PROPERTY
run() {
  local label=$1 module=$2 cfg=$3 expect=$4 prop=$5
  local id=${label//\//_}
  local log="$TMP/$id.log"
  "$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -noGenerateSpecTE \
    -metadir "$TMP/meta-$id" -config "$cfg" "$module.tla" > "$log" 2>&1
  local actual what
  if grep -q "Model checking completed. No error has been found." "$log"; then
    actual=pass; what="-"
  elif what=$(grep -m1 -E "Invariant .* is violated|Action property .* is violated|Temporal propert(y|ies) .*(was|were) violated|Deadlock reached" "$log"); then
    actual=fail
  else
    actual=error; what=$(grep -m1 -E "^Error" "$log" || echo "no TLC verdict")
  fi
  local stats depth ok=1
  stats=$(grep -E "states generated, .* distinct states found" "$log" | tail -1)
  depth=$(grep -m1 -E "depth of the complete state graph" "$log" | sed -E 's/.* is ([0-9]+).*/\1/')
  [ "$actual" = "$expect" ] || ok=0
  # A violation counts only if it is the property under test.
  if [ "$actual" = fail ] && [ -n "$prop" ] && ! printf '%s' "$what" | grep -q "$prop"; then ok=0; fi
  printf '%-4s %-38s expect=%-4s got=%-5s | %s | depth %s | %s\n' \
    "$([ $ok = 1 ] && echo OK || echo BAD)" "$label" "$expect" "$actual" "$stats" "${depth:-?}" "$what"
  if [ $ok = 0 ]; then status=1; fi
  if [ "$actual" != pass ] && { [ $VERBOSE = 1 ] || [ "$actual" = error ]; }; then
    sed -n '/^Error:/,/distinct states found/p' "$log"
  fi
}

echo "== base (Lidwake.cfg: all properties in one run, then one run per property)"
run base/all Lidwake Lidwake.cfg pass ""
for p in $INVARIANTS $PROPERTIES; do
  mkcfg "$TMP/base-$p.cfg" FALSE none "$p"
  run "base/$p" Lidwake "$TMP/base-$p.cfg" pass "$p"
done

echo "== mutations (each must be caught by its property)"
for m in saveAfterPmset:NoOrphanHold startDropsOwned:NoOrphanHold \
         noOrphanGuard:NoOrphanHold recordAfterResume:NoOrphanHold \
         nilClaims:NeverClobberUser clearUnowned:NeverClobberUser \
         dropOwnedOnFail:EventuallyRestored noKillStopped:EventuallyRestored \
         noAssertOnFail:AssertionIffHold \
         typeOverflow:TypeOK; do
  mut=${m%%:*}; p=${m#*:}
  mkcfg "$TMP/bug-$mut.cfg" FALSE "$mut" "$p"
  run "bug-$mut/$p" Lidwake_bug "$TMP/bug-$mut.cfg" fail "$p"
done

echo "== limitation (user sets the flag while lidwake owns it)"
for p in $INVARIANTS $PROPERTIES; do
  case "$p" in NeverClobberUser|EventuallyRestored) e=fail ;; *) e=pass ;; esac
  mkcfg "$TMP/lim-$p.cfg" TRUE none "$p"
  run "limitation/$p" Lidwake "$TMP/lim-$p.cfg" "$e" "$p"
done

echo "== corrupt (journal.json can become unreadable)"
for p in $INVARIANTS $PROPERTIES; do
  case "$p" in NeverClobberUser|EventuallyRestored) e=fail ;; *) e=pass ;; esac
  mkcfg "$TMP/cor-$p.cfg" FALSE none "$p" TRUE
  run "corrupt/$p" Lidwake "$TMP/cor-$p.cfg" "$e" "$p"
done
for p in NoOrphanHold EventuallyNoUnwantedHold; do
  mkcfg "$TMP/cor-old-$p.cfg" FALSE corruptAsUnowned "$p" TRUE
  run "corrupt-bug-corruptAsUnowned/$p" Lidwake_bug "$TMP/cor-old-$p.cfg" fail "$p"
done
for p in NeverQuarantines RestoreNeverQuarantines; do
  mkcfg "$TMP/cor-reach-$p.cfg" FALSE none "$p" TRUE
  run "corrupt-reach/$p" Lidwake "$TMP/cor-reach-$p.cfg" fail "$p"
done
mkcfg "$TMP/cor-pend.cfg" FALSE none NoOrphanHold TRUE TRUE
run "corrupt-limitation-pending/NoOrphanHold" Lidwake "$TMP/cor-pend.cfg" fail NoOrphanHold

exit $status
