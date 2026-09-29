#!/bin/sh
# test/docs.t - the documented suite matches the real one.
#
# WHAT THIS IS LEFT OF. It was test/style.t, which checked 80 columns, syntax,
# naming, tabs, the Python indent step and em-dashes across the whole tree.
# Every one of those is now in test/conventions.t, the SHARED house-conventions
# test vendored into each repo from ~/src/shared-notes/_conventions.t, so
# keeping them here would be two implementations of one rule free to disagree
# which is the shape this repo keeps finding and fixing.
#
# ONE rule was genuinely local and had no home in the shared test, so it stays,
# and the file is renamed to say what it now does. Found drifted BY HAND, which
# is the argument for it: device.t and keymap.t sat in the suite for commits
# without ever reaching the README's table, so the documented suite was smaller
# than the real one and nothing said so. That is this package's own recurring
# shape (TWO COPIES OF ONE FACT) applied to its docs.
#
# It earned its keep again immediately: adding conventions.t to the suite made
# this fail on the same day, naming the missing README row.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init docs

cd "$HERE"
bad=""

# --- every test is listed in the README --------------------------------------
_n=0
for f in test/*.t; do
  _t=$(basename "$f")
  _n=$((_n + 1))
  grep -q "^    $_t " README.md || bad="$bad
  $_t is not in the README's test table, so the documented suite is smaller
  than the real one"
done

# DERIVED, not a floor: the glob is the whole corpus, so if it ever stops
# matching this check passes having compared nothing at all.
[ "$_n" -gt 0 ] || bad="$bad
  the test/*.t glob matched nothing, so this check compared no tests to the
  README and its success means nothing"

[ -z "$bad" ] || fail "documentation drift:$bad"
pass "$_n tests, all in the README table"
