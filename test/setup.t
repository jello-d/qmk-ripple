#!/bin/sh
# test/setup.t - the installer matrix, entirely inside a scratch PREFIX.
#
# setup.sh grew a mode at a time and each mode broke a check written for the
# other one, twice: copy mode reported the two user-only commands as "[FAIL]
# missing" from a system tree they are deliberately not in, and copy mode also
# warned that the system prefix was "not on PATH", advice which, followed,
# creates the double the same script refuses to create. Both are pinned here.
#
# Nothing outside T is read for state or written at all: SHARED_BIN is
# redirected into the scratch dir, so the real /usr/local is never consulted.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init setup

S=$HERE/setup.sh
U=$T/user          # a user-mode prefix
Y=$T/opt           # a system-mode prefix
P=$T/published     # stands in for /usr/local/bin
mkdir -p "$P"

# Keep the real /usr/local out of every invocation.
run() { _v=$1; shift; env SHARED_BIN="$P" "$@" sh "$S" "$_v"; }

# --- user mode: a PAYLOAD tree, with bin/ linked into it -------------------
# The links must resolve into the payload and NOT into this checkout. Under a
# provisioner the checkout is ~/.cache/tackup/pkgs/qmk-ripple, re-cloned every
# sweep and wiped on demand, so a link resolving in there works until it
# abruptly does not. That was the live state on 2026-09-30.
PAY=$U/share/qmk-ripple
run install PREFIX="$U" >/dev/null
[ -d "$PAY" ] || fail "user mode: no payload at $PAY"
[ -L "$PAY" ] && fail "user mode: the payload is a SYMLINK, not a real tree"
for c in qmk-ripple qmk-ripple-admin qmk-ripple-bootstrap; do
  [ -L "$U/bin/$c" ] || fail "user mode: $c is not a symlink"
  [ "$(readlink -f "$U/bin/$c")" = "$PAY/bin/$c" ] \
    || fail "user mode: $c resolves to $(readlink -f "$U/bin/$c"), not into
the payload at $PAY/bin/$c"
  [ "$(readlink -f "$U/bin/$c")" = "$HERE/bin/$c" ] \
    && fail "user mode: $c still resolves into the CHECKOUT, which is the
symlink-into-clone model this conversion removed"
done

# EVERY DIR A COMMAND READS AS A SIBLING must be in the payload, or it resolves
# into an empty tree and fails at RUNTIME rather than at install. lib/ is
# imported by all three; qmk/ carries `build` (admin build runs
# pkg_root()/qmk/build) and ripple_config.h (firmware_defaults reads it).
for d in bin lib qmk; do
  [ -d "$PAY/$d" ] || fail "user mode: payload has no $d/, so a command that
resolves \$(dirname \$(dirname \$0))/$d finds nothing"
done
[ -f "$PAY/lib/qmkripple.py" ] || fail "user mode: payload has no
lib/qmkripple.py; every command fails at startup"
[ -f "$PAY/qmk/build" ] || fail "user mode: payload has no qmk/build, so
\`qmk-ripple-admin build\` breaks and no hardware-free test would notice"
[ -f "$PAY/qmk/ripple_config.h" ] || fail "user mode: payload has no
qmk/ripple_config.h, which firmware_defaults() reads"

# The payload is a COPY, not a link farm back into the checkout.
[ -L "$PAY/lib/qmkripple.py" ] && fail "user mode: the payload's lib is a
SYMLINK; the point of the payload is that it survives the clone being wiped"

# ...and the commands actually RUN through the link, which is the only proof
# that self-location resolved to the payload rather than merely looking right.
for c in qmk-ripple qmk-ripple-admin qmk-ripple-bootstrap; do
  "$U/bin/$c" --help >/dev/null 2>&1 \
    || fail "user mode: $c does not run through the payload link"
done

[ -e "$U/lib/qmkripple.py" ] && fail "user mode installed a top-level lib/
(it should not: the payload carries its own, and $PREFIX/lib is copy mode's)"
run check PREFIX="$U" >/dev/null \
  || fail "user mode: check failed on a good install"

# idempotent, and leaving no staging crumbs behind
run install PREFIX="$U" >/dev/null
run check PREFIX="$U" >/dev/null \
  || fail "user mode: not idempotent"
for _crumb in "$PAY.new" "$PAY.old"; do
  [ -e "$_crumb" ] && fail "install left a staging crumb at $_crumb"
done

# A STALE PAYLOAD MUST FAIL, or an upgrade that half-ran reads as healthy.
printf 'stale\n' > "$PAY/lib/qmkripple.py"
run check PREFIX="$U" >/dev/null 2>&1 \
  && fail "a STALE payload lib passed check"
run install PREFIX="$U" >/dev/null   # heal
# ...and so must a payload missing a dir the commands read.
rm -rf "$PAY/qmk"
run check PREFIX="$U" >/dev/null 2>&1 \
  && fail "a payload missing qmk/ passed check"
run install PREFIX="$U" >/dev/null   # heal
run check PREFIX="$U" >/dev/null \
  || fail "check still fails after a re-install healed the payload"

# --- system mode: real files, the shared subset only, lib alongside --------
run install PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null
[ -f "$Y/bin/qmk-ripple" ] || fail "system mode: no bin/qmk-ripple"
[ -L "$Y/bin/qmk-ripple" ] && fail "system mode: qmk-ripple is a SYMLINK; the
greeter cannot follow one into a 0750 home, which is the whole point"
[ -f "$Y/lib/qmkripple.py" ] || fail "system mode: lib/ did not travel with
the tree, so the copied command cannot import it"
for c in qmk-ripple-admin qmk-ripple-bootstrap; do
  [ -e "$Y/bin/$c" ] && fail "system mode: $c is human-run and must not be in
a root-owned tree (CLASSIFY PER COMMAND)"
done
run check PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null \
  || fail "system mode: check failed on a good install"

# The check must not ask the two user-only commands to be present here.
_out=$(run check PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 2>&1)
case "$_out" in
  *"missing $Y/bin/qmk-ripple-admin"*)
    fail "system mode: check demands a command that mode does not install" ;;
esac
# ...and must not advise putting the system tree on PATH.
case "$_out" in
  *"$Y/bin is not on PATH"*)
    fail "system mode: check advises adding the system tree to PATH, which
would resolve the command twice" ;;
esac

# --- system mode rots two ways, and both are caught ------------------------
printf '#!/bin/sh\n' > "$Y/bin/qmk-ripple"
run check PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null 2>&1 \
  && fail "system mode: a STALE copy passed check"
run install PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null   # heal
ln -sf "$HERE/bin/qmk-ripple" "$Y/bin/qmk-ripple"
run check PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null 2>&1 \
  && fail "system mode: a SYMLINK where a real file belongs passed check"
run install PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null   # heal
rm -f "$Y/lib/qmkripple.py"
run check PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null 2>&1 \
  && fail "system mode: a missing lib passed check"
run install PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 >/dev/null   # heal

# --- the path audit: a root-executed file needs a safe path, not just a safe
# --- file. /usr/local sat owned by the login user while everything inside it
# --- was root, so the owner could have swapped the directory and changed what
# --- the greeter runs. Every check was green, because each looked at a file.
W=$T/wide/pfx
mkdir -p "$W"
chmod 777 "$T/wide"
run install PREFIX="$W" QMKRIPPLE_INSTALL_COPY=1 >/dev/null
run check PREFIX="$W" QMKRIPPLE_INSTALL_COPY=1 >/dev/null 2>&1 \
  && fail "a world-writable, non-sticky ancestor passed the path audit"
run check PREFIX="$W" QMKRIPPLE_INSTALL_COPY=1 2>&1 \
  | grep -q "world-writable" \
  || fail "the audit failed without naming the world-writable directory"
chmod 755 "$T/wide"
run check PREFIX="$W" QMKRIPPLE_INSTALL_COPY=1 >/dev/null 2>&1 \
  || fail "the audit still fails after the ancestor was tightened"

# NOT EXERCISED HERE: the owner-mismatch arm (an ancestor owned by another
# non-root user), which is the /usr/local case itself. Constructing it needs
# root to chown, so this suite cannot reach it; said plainly rather than
# left to look covered.

# --- and the audit must cover the PUBLISH path, not just the prefix tree ----
# The two audited paths both walked $PREFIX, so the check was blind to the one
# path that actually decides what the greeter runs: whoever can replace a
# directory on $SHARED_BIN chooses the binary, however tidy /opt is. Measured
# on the real box 2026-09-29, where the /opt side was green while /usr/local
# was still owned by the login user.
#
# Driven through the world-writable arm rather than owner-mismatch, because
# that one needs no chown and hits the same call site.
V=$T/pubwide
mkdir -p "$V/bin"
ln -s "$Y/bin/qmk-ripple" "$V/bin/qmk-ripple"
chmod 777 "$V"
env SHARED_BIN="$V/bin" PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 \
  sh "$S" check >/dev/null 2>&1 \
  && fail "an unsafe directory on the PUBLISH path passed the audit; the
greeter resolves the command through there, so that path decides what runs"
env SHARED_BIN="$V/bin" PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 \
  sh "$S" check 2>&1 | grep -q "$V" \
  || fail "the audit failed without naming the unsafe publish directory"
chmod 755 "$V"
env SHARED_BIN="$V/bin" PREFIX="$Y" QMKRIPPLE_INSTALL_COPY=1 \
  sh "$S" check >/dev/null 2>&1 \
  || fail "the publish-path audit still fails after the directory was
tightened"

# --- the shadow guard ------------------------------------------------------
# Publish the shared command, then a user install must NOT make a second copy.
ln -s "$Y/bin/qmk-ripple" "$P/qmk-ripple"
rm -rf "$U"
run install PREFIX="$U" >/dev/null
[ -e "$U/bin/qmk-ripple" ] && fail "a published command was installed into the
user prefix as well: that is the banned double, and /usr/local wins"
for c in qmk-ripple-admin qmk-ripple-bootstrap; do
  [ -L "$U/bin/$c" ] || fail "the guard skipped $c, which is not published"
done
run check PREFIX="$U" >/dev/null || fail "check failed with the command
correctly published elsewhere and absent here"

# And the double, if someone makes it by hand, must FAIL.
ln -s "$HERE/bin/qmk-ripple" "$U/bin/qmk-ripple"
run check PREFIX="$U" >/dev/null 2>&1 \
  && fail "a command on PATH TWICE passed check"
rm -f "$U/bin/qmk-ripple"

# --- XDG_DATA_HOME relocates the payload -----------------------------------
# A provisioner PASSES this, so honouring it is a contract and not a detail.
# Asserted once, somewhere it actually proves something: pointing it away from
# $PREFIX must move the payload and the links must follow.
R=$T/relocated
rm -rf "$U"
run install PREFIX="$U" XDG_DATA_HOME="$R" >/dev/null
[ -d "$R/qmk-ripple/bin" ] || fail "XDG_DATA_HOME was ignored: no payload at
$R/qmk-ripple"
[ -e "$U/share/qmk-ripple" ] && fail "XDG_DATA_HOME was set but a payload was
built under \$PREFIX/share anyway"
_want=$R/qmk-ripple/bin/qmk-ripple-admin
[ "$(readlink -f "$U/bin/qmk-ripple-admin")" = "$_want" ] \
  || fail "the link did not follow the relocated payload"
run check PREFIX="$U" XDG_DATA_HOME="$R" >/dev/null \
  || fail "check failed against a relocated payload"
rm -rf "$U" "$R"
run install PREFIX="$U" >/dev/null

# --- uninstall removes ours and leaves a stranger alone --------------------
# rm FIRST, rather than writing over the path in place. It now resolves into
# the payload rather than the checkout, so the blast radius is smaller than it
# was, but the habit stays: this exact line, before the payload existed, wrote
# THROUGH the link and truncated bin/qmk-ripple-admin in the repo to one line.
rm -f "$U/bin/qmk-ripple-admin"
printf '#!/bin/sh\n' > "$U/bin/qmk-ripple-admin"   # someone else's, same name
chmod +x "$U/bin/qmk-ripple-admin"
run uninstall PREFIX="$U" >/dev/null
[ -f "$U/bin/qmk-ripple-admin" ] || fail "uninstall deleted a same-named
command it does not own"
[ -e "$U/bin/qmk-ripple-bootstrap" ] && fail "uninstall left our own link"
# The PAYLOAD goes too, or an uninstall leaves the bulk of the install behind.
[ -e "$U/share/qmk-ripple" ] && fail "uninstall left the payload at
$U/share/qmk-ripple"

pass "user/system modes, staleness, the shadow guard and uninstall"
