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
[ "$_nsh" -ge 16 ] || bad="$bad
classified only $_nsh shell files (expected >=16): _lang has stopped
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
# The rule covers "prose, comments, and documentation alike", but this only
# looked at *.md, so an em-dash in a code comment was never checked. Now every
# text file is.
#
# The pattern is built from its UTF-8 bytes rather than written literally, so
# this file does not contain the character it searches for. Otherwise style.t
# has to exempt itself, and a self-exemption is how the one file most likely to
# be edited stops being checked.
_emdash=$(printf '\342\200\224')
for f in $(git ls-files --cached --others --exclude-standard 2>/dev/null); do
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue
  if grep -qF "$_emdash" "$f" 2>/dev/null; then
    bad="$bad
$f: contains an em-dash"
  fi
done

# --- every test is listed in the README ------------------------------------
# Found drifted, by hand, which is the argument for the check: device.t and
# keymap.t had been in the suite for commits without ever reaching the README's
# table, so the documented suite was smaller than the real one and nothing said
# so. This is the package's own recurring shape (TWO COPIES OF ONE FACT) applied
# to its docs.
for f in test/*.t; do
  _n=$(basename "$f")
  grep -q "^    $_n " README.md || bad="$bad
$_n is not in the README's test table, so the documented suite is smaller
than the real one"
done

# --- NEVER TABS ------------------------------------------------------------
# The convention's own reasoning for why this needs a check rather than a
# habit: an 8-wide tabstop makes a tab and 8 spaces line up by accident, so
# mixed indentation is INVISIBLE until someone opens the file at a different
# tabstop, and it survives for years that way. Make requires a literal tab to
# open a recipe line, so Makefiles are the one exemption (qmk/keymap/rules.mk
# is assignments only today, but it is the file that would legitimately gain
# one).
for f in $(git ls-files --cached --others --exclude-standard 2>/dev/null); do
  [ -f "$f" ] || continue
  case "$f" in *.mk|Makefile|*/Makefile) continue ;; esac
  grep -Iq . "$f" 2>/dev/null || continue
  if grep -qP '\t' "$f" 2>/dev/null; then
    bad="$bad
$f: contains a TAB (2 spaces, never tabs)"
  fi
done

# --- python indents in steps of exactly 2 ----------------------------------
# This one guards a 3000-line reindent that nothing else pins, and it cannot
# be written as "the indent is even": 4-space indentation gives 4, 8, 12,
# every one of them even. The invariant is the STEP, so walk the INDENT tokens
# and require each new level to be exactly 2 deeper than the enclosing one.
#
# Continuation lines are deliberately NOT covered: they live inside a logical
# line, produce no INDENT token, and are allowed to align to their opening
# bracket, which is the formatter's call and not ours.
#
# Covers the embedded Python too. test/*.t run Python through `py - <<'EOF'`,
# so a .t file holds 2-space shell and its own Python at once, and the eleven
# blocks in this suite would otherwise be the one place 4-space could creep
# back unseen.
py - <<'EOF' || bad="$bad
python indentation is not in steps of 2 (see above)"
import io
import subprocess
import sys
import tokenize


def tracked():
  out = subprocess.run(["git", "ls-files", "--cached", "--others",
                        "--exclude-standard"], capture_output=True, text=True)
  return [p for p in out.stdout.split("\n") if p]


def is_python(path):
  """Suffix for a LOADED module, shebang for an EXECUTED one: the same two
  declarations the shell half of this test classifies on."""
  if path.endswith(".py"):
    return True
  try:
    with open(path) as f:
      first = f.readline()
  except (OSError, UnicodeDecodeError):
    return False
  return first.startswith("#!") and "python" in first


def heredocs(path):
  """Every `py - ... <<'EOF'` body in a shell file, as (firstline, source)."""
  with open(path) as f:
    lines = f.read().splitlines(keepends=True)
  out = []
  i = 0
  while i < len(lines):
    if not (lines[i].startswith("py -") and "<<'EOF'" in lines[i]):
      i += 1
      continue
    quotes = 0                      # the opener may wrap over a `|| fail "..."`
    while i < len(lines):
      quotes += lines[i].count('"')
      i += 1
      if quotes % 2 == 0:
        break
    start = i
    while i < len(lines) and lines[i].rstrip("\n") != "EOF":
      i += 1
    out.append((start + 1, "".join(lines[start:i])))
  return out


def check(label, src):
  """Report every INDENT whose step away from its enclosing level is not 2."""
  bad = []
  stack = [0]
  try:
    for t in tokenize.tokenize(io.BytesIO(src.encode()).readline):
      if t.type == tokenize.INDENT:
        lvl = len(t.string.expandtabs(8))
        if lvl - stack[-1] != 2:
          bad.append("%s:%d indents %d past %d (want a step of 2)"
                     % (label, t.start[0], lvl - stack[-1], stack[-1]))
        stack.append(lvl)
      elif t.type == tokenize.DEDENT and len(stack) > 1:
        stack.pop()
  except (tokenize.TokenError, IndentationError, SyntaxError) as e:
    bad.append("%s: will not tokenize: %s" % (label, e))
  return bad


bad = []
n_files = 0
n_blocks = 0
for p in tracked():
  if p.endswith(".t"):
    for line, src in heredocs(p):
      n_blocks += 1
      bad += check("%s (heredoc at line %d)" % (p, line), src)
    continue
  if not is_python(p):
    continue
  n_files += 1
  with open(p) as f:
    bad += check(p, f.read())

# A derived sweep that finds nothing passes vacuously, same trap as the syntax
# check above, so floor both counts.
if n_files < 5:
  bad.append("only %d python files classified (expected >=5)" % n_files)
if n_blocks < 13:
  bad.append("only %d heredoc blocks found (expected >=13): the extractor has "
             "stopped matching and this check is vacuous" % n_blocks)

for b in bad:
  print("  " + b, file=sys.stderr)
if bad:
  sys.exit(1)
print("  2-space steps in %d python files and %d embedded blocks"
      % (n_files, n_blocks))
EOF

if [ -n "$bad" ]; then
  printf '%s\n' "$bad" | sed '/^$/d' | sed 's/^/  /' >&2
  fail "style violations above"
fi

pass "80 cols, syntax, naming, 2-space steps, no tabs, no em-dashes"
