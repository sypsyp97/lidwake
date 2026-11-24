#!/usr/bin/env bash
# Doctor for verifying lidwake on isolated state. Prints evidence; exits 1 on any FAIL.
#   LIDWAKE_STATE_DIR=<iso>/state CFFIXED_USER_HOME=<iso>/home .claude/skills/verify-lidwake/doctor.sh
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
BIN="$ROOT/.build/debug/lidwake"
fail=0
say() { printf '%-5s %s\n' "$1" "$2"; [ "$1" = FAIL ] && fail=1; return 0; }

# identity: the binary under test is built from this tree, and the tree is committed
head=$(git -C "$ROOT" rev-parse --short HEAD)
dirty=$(git -C "$ROOT" status --porcelain -- Sources Package.swift)
[ -z "$dirty" ] && say OK "tree $ROOT at $head, Sources clean" || say FAIL "uncommitted Sources changes: $dirty"
if [ -x "$BIN" ]; then
  newer=$(find "$ROOT/Sources" "$ROOT/Package.swift" -newer "$BIN" -type f | head -1)
  [ -z "$newer" ] && say OK "binary $BIN newer than every source ($(shasum "$BIN" | cut -c1-12))" \
    || say FAIL "binary older than $newer: run swift build in $ROOT"
else
  say FAIL "no binary at $BIN: run swift build in $ROOT"
fi

# isolation: never the real state dir or the real home
state=${LIDWAKE_STATE_DIR:-}
home=${CFFIXED_USER_HOME:-}
canon() { (mkdir -p "$1" && cd "$1" && pwd -P); }
live=$(canon "$HOME/.lidwake")
if [ -z "$state" ]; then
  say FAIL "LIDWAKE_STATE_DIR unset"
else
  cs=$(canon "$state")
  case "$cs/" in
    "$live/"*) say FAIL "state dir $state resolves into the live state dir $live" ;;
    *) say OK "state dir $state (canonical $cs)" ;;
  esac
fi
case "$home" in
  ""|"$HOME"|"$HOME/") say FAIL "CFFIXED_USER_HOME unset or the real home (herdr socket would be live)" ;;
  *) say OK "home $home (herdr socket $home/.config/herdr/herdr.sock: $([ -S "$home/.config/herdr/herdr.sock" ] && echo present || echo absent))" ;;
esac

# ownership: nobody holds the isolated lock
if [ -n "$state" ] && [ -e "$state/lock" ]; then
  holders=$(lsof -t "$state/lock" 2>/dev/null | tr '\n' ' ')
  [ -z "$holders" ] && say OK "lock $state/lock free" || say FAIL "lock $state/lock held by pid $holders"
else
  say OK "no lock file yet"
fi

# live agent: read-only facts (never driven)
live=$(launchctl print "gui/$(id -u)/com.lidwake.agent" 2>/dev/null | awk '/^\tpid = /{print $3}')
say INFO "live agent pid ${live:-none}; SleepDisabled=$(pmset -g | awk '/SleepDisabled/{print $2}')"

# inputs that isolation cannot hide: open Claude Code task files, power source
tasks=$(lsof -u "$(id -u)" 2>/dev/null | grep -c "/private/tmp/claude-$(id -u)/.*/tasks/.*\.output")
say INFO "open task output files: $tasks (idle scenarios need 0)"
say INFO "power: $(pmset -g batt | sed -n 1p)"

exit $fail
