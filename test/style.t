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
. "$(dirname "$0")/harness_lib"
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

# --- which language is a file? ASK IT, do not key on the name --------------
# The naming convention strips the language tag from anything EXECUTED
# (`qmk/build`, `sim/ripple`), precisely so the implementation can change
# without breaking callers. That also means a hardcoded `*.sh` list silently
# stops finding them -- and a hand-maintained list was already the weaker
# problem here, since a NEW script joined neither check until someone
# remembered to add it. So classify by the two things that actually declare a
# language:
#
#   EXECUTED -> its shebang.  LOADED -> its marker. A sourced shell file wears
#   `_lib` (descriptive, per the convention: `.` dispatches on nothing, so a
#   language tag buys nothing); an imported Python module must keep `.py`,
#   because `import` demands it.
#
# The `_lib` arm is load-bearing and nearly went missing: `test/harness_lib`
# has no suffix AND no shebang, so without it the harness silently left the
# syntax check while every test kept passing -- the exact shrinkage the
# renaming rule warns about. `_` is what makes that arm writable at all; with
# `harness-lib` there is no way to tell the classifier apart from a command.
#
# .githooks/pre-commit is picked up by this and was missed by the old list.
_lang() {
  case "$1" in
    *_lib) echo shell; return ;;
    *.sh)  echo shell; return ;;
    *.py)  echo python; return ;;
  esac
  case "$(head -1 "$1")" in
    '#!'*python*) echo python ;;
    '#!'*sh)      echo shell ;;
    *)            echo "" ;;
  esac
}

_nsh=0
_npy=0
for f in $(git ls-files --cached --others --exclude-standard 2>/dev/null); do
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue
  case "$(_lang "$f")" in
    # Shell: POSIX syntax, no bashisms.
    shell)
      _nsh=$((_nsh + 1))
      if command -v dash >/dev/null 2>&1; then
        dash -n "$f" 2>/dev/null || bad="$bad
$f: dash -n rejects it"
      else
        sh -n "$f" 2>/dev/null || bad="$bad
$f: sh -n rejects it"
      fi ;;
    # Python: it must at least compile.
    python)
      _npy=$((_npy + 1))
      python3 -m py_compile "$f" 2>/dev/null || bad="$bad
$f: does not compile" ;;
  esac
done
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true

# A derived list can silently become EMPTY, and then every syntax check above
# passes by finding nothing. That is the failure mode the old hardcoded list
# did not have, so pay for it with a floor: these counts only ever grow.
[ "$_nsh" -ge 14 ] || bad="$bad
classified only $_nsh shell files (expected >=14): _lang has stopped
recognising them, so the syntax check is passing vacuously"
[ "$_npy" -ge 5 ] || bad="$bad
classified only $_npy python files (expected >=5): _lang has stopped
recognising them, so the compile check is passing vacuously"

# --- nothing EXECUTED may carry a language tag -----------------------------
# The naming rule: a suffix on an executed file leaks the implementation into
# every caller, so rewriting `foo.py` in another language breaks them all for
# no reason. A LOADED file keeps a marker (test/harness_lib, qmkripple.py), and
# setup.sh is frozen by the fleet install contract, so both are exempt.
for f in $(git ls-files --cached --others --exclude-standard 2>/dev/null); do
  [ -x "$f" ] || continue
  case "$f" in setup.sh) continue ;; esac
  case "$f" in
    *.sh|*.py|*.bash|*.rb|*.pl)
      bad="$bad
$f: executable with a language-tag suffix; drop it (callers should not
know the implementation language)" ;;
  esac
done

# --- and `_lib` means SOURCED, never executed ------------------------------
# This is the assertion the `_` separator exists to make writable: `_`
# separates a name from its CLASSIFIER, so `*_lib` is machine-parseable in a
# way `*-lib` is not (is `mux-log-lib` the file `mux-log-lib`, or `mux-log`
# classified `lib`? Unanswerable). Having taken the naming, take the check too,
# or the convention costs a rename and buys nothing.
for f in $(git ls-files --cached --others --exclude-standard '*_lib' \
           2>/dev/null); do
  [ -f "$f" ] || continue
  [ -x "$f" ] && bad="$bad
$f: named _lib but EXECUTABLE. The marker promises it is sourced; an exec
bit says a caller may run it, and only one of those can be true."
  head -1 "$f" | grep -q '^#!' && bad="$bad
$f: named _lib but carries a shebang, which claims it is executed"
done

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

pass "80 cols, syntax by shebang, no suffix on an executed file, no em-dashes"
