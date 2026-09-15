#!/bin/sh
# test/style.t - the cheapest empirical checks, across the WHOLE tree.
#
# The repo has a pre-commit hook for the 80-column limit, but it only sees
# STAGED lines: a file that drifted before the hook existed, or landed via
# --no-verify, stays wrong and nothing says so. This asserts the invariant over
# every tracked file instead of over one diff.
#
# It also runs the per-language syntax check the project's own conventions ask
# for, so a broken script cannot reach a box and fail at a screen blank.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init style

cd "$HERE"
bad=""

# --- 80 columns, every tracked text file -----------------------------------
# --cached AND --others: `git ls-files` alone lists only TRACKED files, so a
# brand-new file is unchecked until after it is committed -- which is exactly
# when the pre-commit hook rejects it. Ask about the working tree instead.
for f in $(git ls-files --cached --others --exclude-standard 2>/dev/null); do
  [ -f "$f" ] || continue
  case "$f" in *.json|LICENSE) continue ;; esac
  # A binary file has no columns to speak of.
  grep -Iq . "$f" 2>/dev/null || continue
  _over=$(awk 'length>80{print FILENAME":"FNR" ("length" cols)"}' "$f")
  [ -n "$_over" ] && bad="$bad
$_over"
done

# --- shell: POSIX syntax, no bashisms --------------------------------------
for f in setup.sh qmk/build.sh test/run test/lib.sh test/*.t; do
  [ -f "$f" ] || continue
  if command -v dash >/dev/null 2>&1; then
    dash -n "$f" 2>/dev/null || bad="$bad
$f: dash -n rejects it"
  else
    sh -n "$f" 2>/dev/null || bad="$bad
$f: sh -n rejects it"
  fi
done

# --- python: it must at least compile --------------------------------------
for f in bin/qmk-ripple bin/qmk-ripple-admin bin/qmk-ripple-bootstrap \
         lib/qmkripple.py sim/ripple.py; do
  [ -f "$f" ] || continue
  python3 -m py_compile "$f" 2>/dev/null || bad="$bad
$f: does not compile"
done
rm -rf bin/__pycache__ lib/__pycache__ sim/__pycache__ __pycache__

# --- every executable in bin/ is executable and has a shebang --------------
for f in bin/*; do
  [ -x "$f" ] || bad="$bad
$f: in bin/ but not executable"
  head -1 "$f" | grep -q '^#!' || bad="$bad
$f: no shebang"
done

# --- no em-dashes, per the project's writing rule --------------------------
for f in $(git ls-files --cached --others --exclude-standard '*.md' \
           2>/dev/null); do
  if grep -q "—" "$f" 2>/dev/null; then
    bad="$bad
$f: contains an em-dash"
  fi
done

if [ -n "$bad" ]; then
  printf '%s\n' "$bad" | sed '/^$/d' | sed 's/^/  /' >&2
  fail "style violations above"
fi

pass "80 cols, shell syntax, python compiles, shebangs, no em-dashes"
