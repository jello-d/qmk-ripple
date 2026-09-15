#!/bin/sh
# test/setup.t - the installer matrix, entirely inside a scratch PREFIX.
#
# setup.sh grew a mode at a time and each mode broke a check written for the
# other one, twice: copy mode reported the two user-only commands as "[FAIL]
# missing" from a system tree they are deliberately not in, and copy mode also
# warned that the system prefix was "not on PATH" -- advice which, followed,
# creates the double the same script refuses to create. Both are pinned here.
#
# Nothing outside T is read for state or written at all: SHARED_BIN is
# redirected into the scratch dir, so the real /usr/local is never consulted.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init setup

S=$HERE/setup.sh
U=$T/user          # a user-mode prefix
Y=$T/opt           # a system-mode prefix
P=$T/published     # stands in for /usr/local/bin
mkdir -p "$P"

# Keep the real /usr/local out of every invocation.
run() { _v=$1; shift; env SHARED_BIN="$P" "$@" sh "$S" "$_v"; }

# --- user mode: symlinks, all three commands -------------------------------
run install PREFIX="$U" >/dev/null
for c in qmk-ripple qmk-ripple-admin qmk-ripple-bootstrap; do
  [ -L "$U/bin/$c" ] || fail "user mode: $c is not a symlink"
  [ "$(readlink -f "$U/bin/$c")" = "$HERE/bin/$c" ] \
    || fail "user mode: $c does not resolve into the checkout"
done
[ -e "$U/lib/qmkripple.py" ] && fail "user mode installed lib/ (it should not:
the symlink resolves back to the checkout, where lib already sits)"
run check PREFIX="$U" >/dev/null || fail "user mode: check failed on a good
install"

# idempotent
run install PREFIX="$U" >/dev/null
run check PREFIX="$U" >/dev/null || fail "user mode: not idempotent"

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

# --- uninstall removes ours and leaves a stranger alone --------------------
# rm FIRST. That path is currently our symlink into the checkout, and writing
# through it would edit the repo -- which is exactly what this line did on its
# first run, truncating bin/qmk-ripple-admin to one line.
rm -f "$U/bin/qmk-ripple-admin"
printf '#!/bin/sh\n' > "$U/bin/qmk-ripple-admin"   # someone else's, same name
chmod +x "$U/bin/qmk-ripple-admin"
run uninstall PREFIX="$U" >/dev/null
[ -f "$U/bin/qmk-ripple-admin" ] || fail "uninstall deleted a same-named
command it does not own"
[ -e "$U/bin/qmk-ripple-bootstrap" ] && fail "uninstall left our own link"

pass "user/system modes, staleness, the shadow guard and uninstall"
