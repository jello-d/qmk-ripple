# test/lib.sh - harness for qmk-ripple's shell tests (test/*.t),
# sourced by each one.
#
# Call `harness_init <name>`: sets HERE (the repo root, so a test reaches bin/,
# lib/, qmk/, setup.sh), a private scratch dir T removed on exit, and the
# pass/fail helpers. Everything a test writes goes inside T.
#
# NO HARDWARE, EVER. The whole suite runs with no keyboard attached and touches
# no system path: anything that would talk to the board uses a VID/PID that
# cannot exist, and anything that would install uses a PREFIX under T. A test
# that needs the real device belongs in `qmk-ripple-admin selftest`, which is
# the hardware suite and says so.
#
# Deliberately mirrors vigilance's test/lib.sh so a person moving between the
# two repos does not have to learn a second harness.
harness_init() {   # <name>
  TEST_NAME=$1
  HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT INT TERM
  # A vid:pid no board answers, so device paths take the not-found branch
  # instead of finding the developer's actual keyboard mid-test.
  ABSENT="--vid dead --pid beef"
  _TREE0=$(_tree_state)
}
# A test must not modify the checkout. It is easy to breach by accident: an
# install fixture leaves symlinks POINTING AT the repo, and a later `>` through
# one of those edits the real file. That happened -- test/setup.t truncated
# bin/qmk-ripple-admin to a single line on its first run. So snapshot the
# working tree at init and refuse to pass if it moved.
_tree_state() {
  git -C "$HERE" status --porcelain 2>/dev/null | sort || true
}
_guard_tree() {
  [ -n "${_TREE0:-}" ] || return 0
  if [ "$(_tree_state)" != "$_TREE0" ]; then
    printf 'FAIL %s: the test MODIFIED THE CHECKOUT (a write through a\n' \
      "$TEST_NAME" >&2
    printf '     symlink into the repo). Diff:\n' >&2
    git -C "$HERE" status --short >&2
    exit 1
  fi
}

pass() { _guard_tree; printf 'ok   %s%s\n' "$TEST_NAME" "${1:+ ($1)}"; }
fail() { printf 'FAIL %s: %s\n' "$TEST_NAME" "$1" >&2; exit 1; }
skip() { printf 'SKIP %s: %s\n' "$TEST_NAME" "$1"; exit 0; }

# py <<'EOF' ... : run python with the repo's lib/ importable. Used by the
# tests that pin a host-side table against its firmware counterpart.
py() {
  PYTHONPATH="$HERE/lib" python3 "$@"
}
