#!/bin/sh
# test/keymap.t - the keymap is the board default plus a KNOWN, SHORT list of
# deliberate changes, and the build cannot silently revert it.
#
# Two failures this pins, both of which already happened:
#
#  1. build.sh copied the board's default keymap over the assembled one on
#     EVERY build, so a mapping change was reverted by the next rebuild with
#     nothing said. Any keymap work would have looked like it "didn't take".
#  2. The QMK Configurator round-trip wrapped four keycodes it did not
#     recognise as ANY(RGB_M_P) and friends. Harmless in isolation, but it is
#     an unintended edit riding along with an intended one, and the only way to
#     notice is to diff EVERY keycode rather than eyeball the two you meant.
#
# So the check is: our keymap differs from the board default at exactly the
# indices listed in CHANGES, and nowhere else. That also makes an upstream
# keymap revision visible instead of silently diverging.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init keymap

OURS=$HERE/qmk/keymap/keymap.c
[ -f "$OURS" ] || fail "no qmk/keymap/keymap.c; build.sh would fall back to the
board default and any mapping change would be lost"

QMK=${VIAL_QMK:-$HOME/src/vial-qmk}
DEF=$QMK/keyboards/drop/cstm65/keymaps/default/keymap.c

# --- build.sh must PREFER ours, with no qmk tree involved ------------------
# Stub `qmk` so build.sh's final `exec qmk compile` cannot run, and give it a
# fake board tree whose default keymap is recognisable. Then assert which file
# landed.
mkdir -p "$T/bin" "$T/qmk/keyboards/drop/cstm65/keymaps/default"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/qmk"
chmod +x "$T/bin/qmk"
printf '// THE BOARD DEFAULT, NOT OURS\n' \
  > "$T/qmk/keyboards/drop/cstm65/keymaps/default/keymap.c"
env PATH="$T/bin:$PATH" VIAL_QMK="$T/qmk" \
  sh "$HERE/qmk/build.sh" drop/cstm65 ripple-test >/dev/null 2>&1 || true
_landed=$T/qmk/keyboards/drop/cstm65/keymaps/ripple-test/keymap.c
[ -f "$_landed" ] || fail "build.sh assembled no keymap at all"
if grep -q "THE BOARD DEFAULT, NOT OURS" "$_landed"; then
  fail "build.sh overwrote the assembled keymap with the board default: a
mapping change would be silently reverted on the next build"
fi
cmp -s "$_landed" "$OURS" \
  || fail "the assembled keymap is neither ours nor the board default"

# --- and it still falls back when a package carries no keymap -------------
mv "$OURS" "$T/ours.c"
env PATH="$T/bin:$PATH" VIAL_QMK="$T/qmk" \
  sh "$HERE/qmk/build.sh" drop/cstm65 ripple-fallback >/dev/null 2>&1 || true
_fb=$T/qmk/keyboards/drop/cstm65/keymaps/ripple-fallback/keymap.c
mv "$T/ours.c" "$OURS"
grep -q "THE BOARD DEFAULT, NOT OURS" "$_fb" \
  || fail "with no repo keymap, build.sh did not fall back to the board default"

# --- ours vs the REAL board default: only the intended changes ------------
if [ ! -f "$DEF" ]; then
  skip "no qmk tree at $QMK, so our keymap was not diffed against the board
     default. The build-preference checks above DID run."
fi

py - "$OURS" "$DEF" <<'EOF' || fail "the keymap differs from the board default
somewhere other than the changes it declares"
import re, sys

# Every deliberate change, as {layer: {index: keycode}}. Adding a mapping means
# adding a line here, which is the point: an edit cannot arrive unannounced.
CHANGES = {1: {15: "KC_TILD", 41: "KC_GRV"}}


def layers(path):
    src = open(path).read()
    out = {}
    for m in re.finditer(
            r"\[(\d+)\]\s*=\s*LAYOUT_65_ansi_blocker\((.*?)\n\s*\)", src, re.S):
        body = re.sub(r"//[^\n]*", "", m.group(2))
        toks = [t.strip() for t in body.replace("\n", " ").split(",")
                if t.strip()]
        out[int(m.group(1))] = toks
    return out


ours, default = layers(sys.argv[1]), layers(sys.argv[2])
bad = []

if sorted(ours) != sorted(default):
    bad.append("layer sets differ: ours %s, default %s"
               % (sorted(ours), sorted(default)))

for li in sorted(default):
    o, d = ours.get(li, []), default[li]
    if len(o) != len(d):
        bad.append("layer %d has %d keycodes, the default has %d"
                   % (li, len(o), len(d)))
        continue
    for idx, (a, b) in enumerate(zip(o, d)):
        want = CHANGES.get(li, {}).get(idx)
        if want is not None:
            if a != want:
                bad.append("layer %d index %d should be %s (declared) but is %s"
                           % (li, idx, want, a))
        elif a != b:
            bad.append("layer %d index %d: ours %s, default %s -- an "
                       "UNDECLARED change" % (li, idx, a, b))

# And every declared change must actually be a change, or the list is stale.
for li, ch in CHANGES.items():
    for idx, kc in ch.items():
        if default.get(li, [None] * (idx + 1))[idx] == kc:
            bad.append("layer %d index %d is already %s upstream; the CHANGES "
                       "entry is stale" % (li, idx, kc))

if bad:
    for b in bad:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
print("  keymap = board default + %d declared change(s)"
      % sum(len(c) for c in CHANGES.values()))
EOF

pass "build prefers the repo keymap, and it is the default plus 2 declared keys"
