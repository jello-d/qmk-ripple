#!/bin/sh
# setup.sh -- put the qmk-ripple commands on PATH. No provisioner required.
#
#   sh setup.sh install     symlink bin/* into ~/.local/bin (idempotent)
#   sh setup.sh check       verify those links ([OK]/[FAIL] + exit code)
#   sh setup.sh uninstall   remove only the links that point into THIS checkout
#
# Two callers, one contract:
#   - a human, standalone: clone the repo, run `sh setup.sh install`.
#   - a provisioner: tackup's install_pkg_tree() delegates here when this file
#     is executable ("a package that ships its own setup.sh OWNS its layout
#     mapping"), passing PREFIX / XDG_BIN_HOME / XDG_DATA_HOME. Honouring those
#     is why the same script serves both.
#
# SYMLINKS, not copies, and specifically symlinks whose realpath is the file in
# this checkout: the commands self-locate lib/qmkripple.py by resolving their
# own path THROUGH the link, and a provisioner's "is it installed?" test
# compares realpaths. A copy would break both.
#
# NON-PRIVILEGED on purpose. This never uses sudo, because the provisioner's
# package mode is non-privileged. The one privileged step in the package -- the
# raw-HID udev rule -- stays behind `qmk-ripple-admin install`, which is
# reported as a next step below rather than run from here.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
BIN=${XDG_BIN_HOME:-$PREFIX/bin}

usage() {
  echo "usage: sh setup.sh {install | check | uninstall}" >&2
  exit 1
}

# Every command the package ships, discovered rather than listed, so adding one
# to bin/ needs no edit here (and cannot be silently forgotten).
each_bin() {
  for _b in "$HERE"/bin/*; do
    [ -f "$_b" ] && [ -x "$_b" ] && printf '%s\n' "$_b"
  done
}

do_install() {
  mkdir -p "$BIN"
  each_bin | while IFS= read -r b; do
    ln -rsfn "$b" "$BIN/$(basename "$b")"
    echo "linked $BIN/$(basename "$b")"
  done
  _n=$(each_bin | wc -l)
  echo "qmk-ripple: $_n command(s) installed into $BIN"
  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo ""
       echo "NOTE: $BIN is not on your PATH. Add it, or the commands will"
       echo "      not be found. A caller with a minimal environment (a"
       echo "      compositor lock hook, say) needs it too." ;;
  esac
  echo ""
  echo "Next: the raw-HID udev rule, the one privileged step (not done here):"
  echo "    qmk-ripple-admin install"
  echo "On a keyboard that has never run this firmware, start with:"
  echo "    qmk-ripple-bootstrap"
}

do_check() {
  _rc=0
  _n=0
  for b in "$HERE"/bin/*; do
    [ -f "$b" ] && [ -x "$b" ] || continue
    _n=$((_n + 1))
    _l=$BIN/$(basename "$b")
    if [ ! -e "$_l" ]; then
      echo "[FAIL] missing $_l"
      _rc=1
    elif [ "$(readlink -f "$_l")" != "$(readlink -f "$b")" ]; then
      # Not just "a file is there": it must resolve to THIS checkout, or the
      # commands on PATH are someone else's copy and every other check lies.
      echo "[FAIL] $_l does not point into this checkout"
      echo "       ($(readlink -f "$_l") != $(readlink -f "$b"))"
      _rc=1
    else
      echo "[OK]   $_l"
    fi
  done
  [ "$_n" -gt 0 ] || { echo "[FAIL] no executables in $HERE/bin"; _rc=1; }
  case ":$PATH:" in
    *":$BIN:"*) echo "[OK]   $BIN is on PATH" ;;
    *) echo "[WARN] $BIN is not on PATH in this shell" ;;
  esac
  return "$_rc"
}

do_uninstall() {
  for b in "$HERE"/bin/*; do
    [ -f "$b" ] && [ -x "$b" ] || continue
    _l=$BIN/$(basename "$b")
    # Only remove a link we own. A same-named command from somewhere else is
    # left alone rather than silently deleted.
    if [ -L "$_l" ] && \
       [ "$(readlink -f "$_l")" = "$(readlink -f "$b")" ]; then
      rm -f "$_l"
      echo "removed $_l"
    elif [ -e "$_l" ]; then
      echo "left alone (not ours): $_l"
    fi
  done
  echo ""
  echo "The udev rule is NOT removed by this; it is root-owned:"
  echo "    sudo rm -f /etc/udev/rules.d/60-qmk-ripple.rules"
}

case "${1:-}" in
  install)   do_install ;;
  check)     do_check ;;
  uninstall) do_uninstall ;;
  *)         usage ;;
esac
