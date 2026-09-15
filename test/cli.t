#!/bin/sh
# test/cli.t - the exit-code contract, which callers branch on.
#
# These codes are not decoration. A verify hook decides FAULT vs GAP from them,
# and they have been wrong twice:
#
#   - argparse exits 2 on a usage error, the SAME code as "no keyboard". An
#     older deployed binary rejecting a new subcommand therefore looked exactly
#     like an absent board, and the hook read it as a benign no-op and PASSED.
#     Usage errors are EX_USAGE (64) now, and this pins it.
#   - a bare `qmk-ripple off --vid dead` was used as the "no device" case in a
#     verification, but a global option AFTER the subcommand is a usage error,
#     so it was testing argparse, not the device path. Both orders are pinned.
#
# No hardware: every device path uses a vid:pid nothing answers.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init cli

R=$HERE/bin/qmk-ripple
A=$HERE/bin/qmk-ripple-admin

# `|| _r=$?` not a bare call: under set -e a failing command
# aborts the function before it can report the code.
rc() { _r=0; "$@" >/dev/null 2>&1 || _r=$?; echo "$_r"; }

# --- usage errors are 64, and NOT 2 ----------------------------------------
[ "$(rc "$R" bogus-verb)" = 64 ] || fail "unknown subcommand should be 64"
[ "$(rc "$R")" = 64 ] || fail "no subcommand should be 64"
[ "$(rc "$R" off --vid dead)" = 64 ] \
  || fail "a global option AFTER the verb is a usage error, expected 64"
[ "$(rc "$R" set)" = 64 ] || fail "set with no args should be 64"
[ "$(rc "$R" mode sideways)" = 64 ] || fail "an invalid mode should be 64"
[ "$(rc "$A" bogus-verb)" = 64 ] || fail "admin unknown subcommand should be 64"

# --- a missing device is 2, and only with the options in the right place ---
for _v in off on status show save reset; do
  _got=$(rc "$R" --vid dead --pid beef "$_v")
  [ "$_got" = 2 ] || fail "$_v with no board: expected 2, got $_got"
done
[ "$(rc "$R" --vid dead --pid beef get radius)" = 2 ] \
  || fail "get with no board should be 2"
[ "$(rc "$R" --vid dead --pid beef set radius 40)" = 2 ] \
  || fail "set with no board should be 2"

# 2 and 64 must stay distinct, or "cannot check" reads as "nothing to check".
[ "$(rc "$R" bogus-verb)" != "$(rc "$R" --vid dead --pid beef off)" ] \
  || fail "a usage error and an absent keyboard return the SAME code; that
collision is what made a verify hook pass on a stale binary"

# --- an unknown parameter is an error, not a silent no-op ------------------
[ "$(rc "$R" --vid dead --pid beef get nosuchparam)" = 2 ] \
  || fail "an unknown parameter should not be reported as success"

# --- help works for all three, and mentions the contract ------------------
for _b in "$R" "$A" "$HERE/bin/qmk-ripple-bootstrap"; do
  "$_b" --help >/dev/null 2>&1 || fail "$_b --help does not exit 0"
done
"$R" --help 2>&1 | grep -q "status" || fail "qmk-ripple --help omits status"

# --- a closed pipe exits quietly, not with a traceback --------------------
# `check | head -1` printed a BrokenPipeError over otherwise clean output,
# which reads as a crashed tool rather than a truncated pipe.
_out=$("$A" --help 2>&1 | head -1 2>&1) || true
case "$_out" in
  *Traceback*|*BrokenPipe*) fail "a closed stdout produced a traceback" ;;
esac

pass "usage=64, absent=2, distinct, and no traceback on a closed pipe"
