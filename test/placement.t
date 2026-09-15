#!/bin/sh
# test/placement.t - self-location through a published symlink, and the udev
# rule's two grants. Both are what make the greeter case work at all.
#
# SELF-LOCATION: reached through a /usr/local/bin symlink into an /opt tree, a
# command that does not resolve its own real path hunts for lib/ beside the
# LINK and fails to start. Two separate notes claimed our binaries did not do
# this; they always have. Rather than trust either claim, this reproduces the
# exact layout and runs through the link.
#
# THE UDEV RULE needs BOTH grants. uaccess alone is an ACL for the ACTIVE SEAT,
# which at the greeter is the greeter's own account -- so a hook running as the
# login user gets EACCES precisely when the keyboard should go dark.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init placement

# --- the /opt + /usr/local/bin shape ---------------------------------------
OPT=$T/opt/qmk-ripple
PUB=$T/usr/local/bin
mkdir -p "$PUB"
env SHARED_BIN="$T/none" PREFIX="$OPT" QMKRIPPLE_INSTALL_COPY=1 \
  sh "$HERE/setup.sh" install >/dev/null

[ -f "$OPT/bin/qmk-ripple" ] || fail "no system copy to publish"
ln -s "$OPT/bin/qmk-ripple" "$PUB/qmk-ripple"

# Through the link, with no HOME of ours and only a system PATH: this is the
# greeter's view. It must resolve lib/ beside its own TREE, not beside the link.
G=$T/greeterhome
mkdir -p "$G"
_out=$(env -i HOME="$G" PATH="$PUB:/usr/bin:/bin" \
  "$PUB/qmk-ripple" --vid dead --pid beef off 2>&1) || _rc=$?
case "$_out" in
  *"cannot import lib/qmkripple.py"*)
    fail "through the published link the command could not find its lib: it is
not self-locating, and a system install would be dead on arrival" ;;
esac
# It should reach the DEVICE layer and report no board (2), not die at import.
[ "${_rc:-0}" = 2 ] || fail "expected exit 2 (no such board) through the link,
got ${_rc:-0}: $_out"

# The other two are user-only and must NOT be in the system tree at all.
for c in qmk-ripple-admin qmk-ripple-bootstrap; do
  [ -e "$OPT/bin/$c" ] && fail "$c is human-run; it must not be published"
done

# --- every binary self-locates, not just the shared one --------------------
# -admin and -bootstrap are reached through ~/.local/bin symlinks, which is the
# same resolution problem one level down.
for c in qmk-ripple qmk-ripple-admin qmk-ripple-bootstrap; do
  grep -q "os.path.realpath(__file__)" "$HERE/bin/$c" \
    || fail "$c does not resolve its own real path; through a symlink it will
look for lib/ beside the link"
done

# --- the udev rule carries BOTH grants -------------------------------------
py - <<'EOF' || fail "the udev rule would not serve the greeter"
import re
import qmkripple as qr
r = qr.RULE_TEXT
bad = []
rule = [l for l in r.splitlines() if l.startswith("KERNEL==")]
if not rule:
    bad.append("no KERNEL== line in RULE_TEXT")
else:
    line = " ".join(rule)
    if 'TAG+="uaccess"' not in line:
        bad.append('no TAG+="uaccess": a logged-in user could not drive it')
    if 'GROUP="' not in line or 'MODE="' not in line:
        bad.append("no GROUP/MODE: seat-independent access is missing, so the "
                   "greeter pre-session case breaks again")
    if 'GROUP="%s"' % qr.ACCESS_GROUP not in line:
        bad.append("the rule does not use ACCESS_GROUP (%s)" % qr.ACCESS_GROUP)
    if "%04x" % qr.VID not in line or "%04x" % qr.PID not in line:
        bad.append("the rule does not name the VID/PID the tools use")
    if "%" in line:
        bad.append("an unexpanded %% is left in the rule text")
if bad:
    import sys
    for b in bad:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
EOF

# udev's own parser, when available. A rule this repo generates but udev
# rejects would fail at install time on a box, not here.
if command -v udevadm >/dev/null 2>&1; then
  py -c 'import qmkripple as q;open("'"$T"'/r.rules","w").write(q.RULE_TEXT)'
  udevadm verify "$T/r.rules" >/dev/null 2>&1 \
    || fail "udevadm rejects the generated rule"
fi

pass "self-location through a publish, and both udev grants"
