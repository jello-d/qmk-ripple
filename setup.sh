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
# SYMLINKS by default, and specifically symlinks whose realpath is the file in
# this checkout: the commands self-locate lib/qmkripple.py by resolving their
# own path THROUGH the link, and a provisioner's "is it installed?" test
# compares realpaths. A copy would break both.
#
# QMKRIPPLE_INSTALL_COPY=1 switches to real-file COPIES, and also installs
# lib/qmkripple.py, because a symlink farm cannot serve a SYSTEM prefix. The
# clone lives under a login user's home (0750, and ~/.cache is 0700), so
# /usr/local/bin/qmk-ripple as a symlink is a path another user can see and
# cannot follow. That is not hypothetical: with greeter coverage on, the
# keyboard hook was wired into /etc/vigilance/hooks pointing at ~/bin, the
# greeter could not traverse the home, and the screen blanked while the
# keyboard stayed lit -- wired up cleanly, doing nothing.
#
# In copy mode lib/ is copied too, next to bin/ under the same PREFIX, so the
# same self-locating logic (realpath -> ../lib) finds it there.
#
# NON-PRIVILEGED on purpose: this never calls sudo, because the provisioner's
# package mode does not. A system prefix is written by the CALLER running this
# under sudo (which is how tackup does it for vigilance). The one privileged
# step in the package -- the raw-HID udev rule -- stays behind
# `qmk-ripple-admin install`, reported as a next step rather than run here.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
BIN=${XDG_BIN_HOME:-$PREFIX/bin}
LIB=${QMKRIPPLE_LIB_DIR:-$PREFIX/lib}
COPY=${QMKRIPPLE_INSTALL_COPY:-0}

# CLASSIFY PER COMMAND, not per package. Only ONE command here is ever run by
# an identity other than the login user: `qmk-ripple`, which an integrator's
# sleep/wake hook calls as the greeter account so the keyboard darkens before
# anyone has logged in. `qmk-ripple-admin` and `qmk-ripple-bootstrap` are
# human-run (build, flash, audit, one-time setup) and have no business in a
# root-owned tree, so copy mode installs this subset and nothing else.
#
# Which of these is actually PUBLISHED onto PATH is the integrator's call, not
# ours (tackup names them: `share_system_command <prefix> qmk-ripple`). We only
# decide what is ELIGIBLE by putting it in the system tree.
SYSTEM_TOOLS=${QMKRIPPLE_SYSTEM_TOOLS:-qmk-ripple}

# Where an integrator PUBLISHES a shared command. Once qmk-ripple is published
# there, a user-mode install of the SAME name is the banned double: this dir
# precedes ~/.local/bin on PATH, so the system copy silently wins and then rots
# behind the live checkout. We refuse to create that rather than make it and
# describe it.
SHARED_BIN=${SHARED_BIN:-/usr/local/bin}

# published <cmd>: 0 if a shared publish exists that is NOT this checkout's own
# user-mode link (so a plain user install is not mistaken for a publish).
published() {
  _p=$SHARED_BIN/$1
  [ -e "$_p" ] || return 1
  [ "$(readlink -f "$_p")" = "$(readlink -f "$HERE/bin/$1")" ] && return 1
  return 0
}

usage() {
  echo "usage: sh setup.sh {install | check | uninstall}" >&2
  exit 1
}

# Every command the package ships, discovered rather than listed, so adding one
# to bin/ needs no edit here (and cannot be silently forgotten).
each_bin() {
  if [ "$COPY" = 1 ]; then
    # System tree: the shared subset only (see SYSTEM_TOOLS).
    for _b in $SYSTEM_TOOLS; do
      [ -x "$HERE/bin/$_b" ] || { echo "setup.sh: no bin/$_b" >&2; exit 1; }
      printf '%s\n' "$HERE/bin/$_b"
    done
  else
    for _b in "$HERE"/bin/*; do
      [ -f "$_b" ] && [ -x "$_b" ] && printf '%s\n' "$_b"
    done
  fi
}

# _place <src> <dst>: install one file, copy-or-link per mode.
#
# --remove-destination: replacing a file another process is running can fail
# ETXTBSY otherwise; unlinking first lets a live process keep the old inode.
#
# THE CHOWN IS NOT OPTIONAL, and is why this is a function rather than a bare
# cp. Vigilance hit it on a real box: a root install that preserves the
# source's ownership leaves a system binary owned by the LOGIN USER -- a file
# the greeter executes that an unprivileged account can rewrite at will. Plain
# cp does not preserve ownership the way `cp -a` does, but being explicit costs
# nothing and the failure is privilege escalation, so assert it rather than
# rely on a flag's default.
_place() {
  if [ "$COPY" = 1 ]; then
    cp -f --remove-destination "$1" "$2"
    chmod "$3" "$2"
    if [ "$(id -u)" = 0 ]; then chown root:root "$2"; fi
  else
    ln -rsfn "$1" "$2"
  fi
}

do_install() {
  mkdir -p "$BIN"
  if [ "$COPY" = 1 ]; then _verb=copied; else _verb=linked; fi
  _n=0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    _c=$(basename "$b")
    if [ "$COPY" != 1 ] && published "$_c"; then
      echo "SKIP $BIN/$_c: already published at $SHARED_BIN/$_c"
      echo "     (installing it here too would put $_c on PATH TWICE, and"
      echo "      $SHARED_BIN wins -- the shared copy is the only one)"
      continue
    fi
    _place "$b" "$BIN/$_c" 0755
    echo "$_verb $BIN/$_c"
    _n=$((_n + 1))
  done <<EOF
$(each_bin)
EOF
  if [ "$COPY" = 1 ]; then
    # lib travels with the tree: the commands resolve it beside their OWN real
    # path, so under a system prefix it has to be there, not in the checkout.
    mkdir -p "$LIB"
    _place "$HERE/lib/qmkripple.py" "$LIB/qmkripple.py" 0644
    echo "$_verb $LIB/qmkripple.py"
  fi
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
  # The commands import lib/qmkripple.py by resolving their own path. If that
  # is missing they still EXIST and `command -v` still finds them -- they just
  # fail at startup. A caller like panel-power runs them with output discarded
  # and the exit code ignored (deliberately: a dimming hiccup must never wedge
  # a lock screen), so that failure is INVISIBLE downstream and shows up only
  # as a keyboard that quietly stopped blanking. Hence: check it here.
  if [ ! -f "$HERE/lib/qmkripple.py" ]; then
    echo "[FAIL] lib/qmkripple.py missing -- every command will fail to start"
    _rc=1
  elif [ "$COPY" = 1 ] && [ ! -f "$LIB/qmkripple.py" ]; then
    # In copy mode the commands resolve lib next to the PREFIX, not in the
    # checkout, so the copy is what has to be there.
    echo "[FAIL] $LIB/qmkripple.py missing -- copied commands cannot start"
    _rc=1
  elif [ "$COPY" = 1 ] && ! cmp -s "$LIB/qmkripple.py" "$HERE/lib/qmkripple.py"
  then
    echo "[FAIL] $LIB/qmkripple.py is a STALE copy"
    _rc=1
  else
    echo "[OK]   lib/qmkripple.py present"
  fi
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    _n=$((_n + 1))
    _l=$BIN/$(basename "$b")
    if [ "$COPY" != 1 ] && published "$(basename "$b")"; then
      # Published as shared. Absent from ~/.local/bin is CORRECT here; present
      # is the double the standard bans, and it is invisible to a plain
      # `command -v` (one winner reads as no shadow).
      if [ -e "$_l" ] || [ -L "$_l" ]; then
        echo "[FAIL] $(basename "$b") is on PATH TWICE: $_l shadowed by"
        echo "       $SHARED_BIN/$(basename "$b") -- remove the user copy"
        _rc=1
      else
        echo "[OK]   $(basename "$b") published at $SHARED_BIN (not here)"
      fi
      continue
    fi
    if [ ! -e "$_l" ]; then
      echo "[FAIL] missing $_l"
      _rc=1
    elif [ "$COPY" = 1 ]; then
      # Copy mode: a symlink here is the bug tackup documents (a path the
      # greeter can see and cannot follow into a 0750 home), and a copy that
      # has drifted from the checkout is the other one. Both are caught.
      if [ -L "$_l" ]; then
        echo "[FAIL] $_l is a SYMLINK; copy mode needs a real file"
        _rc=1
      elif ! cmp -s "$_l" "$b"; then
        echo "[FAIL] $_l is a STALE copy (differs from the checkout)"
        _rc=1
      else
        echo "[OK]   $_l (copy)"
      fi
    elif [ "$(readlink -f "$_l")" != "$(readlink -f "$b")" ]; then
      # Not just "a file is there": it must resolve to THIS checkout, or the
      # commands on PATH are someone else's copy and every other check lies.
      echo "[FAIL] $_l does not point into this checkout"
      echo "       ($(readlink -f "$_l") != $(readlink -f "$b"))"
      _rc=1
    elif ! "$_l" --help >/dev/null 2>&1; then
      # Present and correctly linked, but does not RUN. Catches a broken
      # layout, a bad interpreter, a syntax error -- all of which a caller
      # that ignores exit codes would swallow.
      echo "[FAIL] $_l is linked but does not run (try: $_l --help)"
      _rc=1
    else
      echo "[OK]   $_l"
    fi
  done <<EOF
$(each_bin)
EOF
  [ "$_n" -gt 0 ] || { echo "[FAIL] no executables in $HERE/bin"; _rc=1; }
  # In copy mode the tree is DELIBERATELY off PATH: only the integrator's
  # single /usr/local/bin symlink is published, so warning that $BIN is absent
  # from PATH would be advice to create the very double the standard bans.
  # Invert it -- the system tree being ON PATH is the thing worth flagging.
  case ":$PATH:" in
    *":$BIN:"*)
      if [ "$COPY" = 1 ]; then
        echo "[WARN] $BIN is ON PATH; the system tree should not be."
        echo "       Publish one symlink instead, or the command resolves twice"
      else
        echo "[OK]   $BIN is on PATH"
      fi ;;
    *)
      if [ "$COPY" = 1 ]; then
        echo "[OK]   $BIN correctly off PATH (published via a symlink)"
      else
        echo "[WARN] $BIN is not on PATH in this shell"
      fi ;;
  esac
  return "$_rc"
}

do_uninstall() {
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    _l=$BIN/$(basename "$b")
    # Only remove a link we own. A same-named command from somewhere else is
    # left alone rather than silently deleted.
    if [ -L "$_l" ] && \
       [ "$(readlink -f "$_l")" = "$(readlink -f "$b")" ]; then
      rm -f "$_l"
      echo "removed $_l"
    elif [ "$COPY" = 1 ] && [ -f "$_l" ] && cmp -s "$_l" "$b"; then
      rm -f "$_l"
      echo "removed $_l (copy)"
    elif [ -e "$_l" ]; then
      echo "left alone (not ours): $_l"
    fi
  done <<EOF
$(each_bin)
EOF
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
