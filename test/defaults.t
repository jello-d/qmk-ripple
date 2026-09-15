#!/bin/sh
# test/defaults.t - the boot defaults live in the C header; everything else
# reads them rather than keeping a copy.
#
# The simulator used to carry its own set of the same eight numbers. That is
# the duplicate that drifts in silence: the sim shows one look, the board
# another, and nothing says which is right. firmware_defaults() parses the
# header instead, so this pins the parser against the header it parses and
# against the x100 conversions the firmware does to the same values.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init defaults

py - "$HERE" <<'EOF' || fail "defaults or codecs have drifted"
import re, sys
import qmkripple as qr

root = sys.argv[1]
hdr = open(root + "/qmk/ripple_config.h").read()
src = open(root + "/qmk/hostctl.c").read()
bad = []

raw = dict((m.group(1), int(m.group(2), 0)) for m in re.finditer(
    r"^#\s*define\s+(RIPPLE_[A-Z_]+)\s+(0[xX][0-9A-Fa-f]+|\d+)", hdr, re.M))
d = qr.firmware_defaults()

# --- the parser reproduces the header --------------------------------------
want = {
    "base": "%02x%02x%02x" % (raw["RIPPLE_BASE_R"], raw["RIPPLE_BASE_G"],
                              raw["RIPPLE_BASE_B"]),
    "hi": "%02x%02x%02x" % (raw["RIPPLE_HI_R"], raw["RIPPLE_HI_G"],
                            raw["RIPPLE_HI_B"]),
    "spread": float(raw["RIPPLE_SPREAD"]),
    "radius": float(raw["RIPPLE_RADIUS"]),
    "keystep": float(raw["RIPPLE_KEYSTEP"]),
    "peak": raw["RIPPLE_PEAK"] / 100.0,
    "fade": float(raw["RIPPLE_FADE"]),
    "falloff": raw["RIPPLE_FALLOFF"] / 100.0,
}
for k, v in want.items():
    if d.get(k) != v:
        bad.append("default %s: header says %r, firmware_defaults says %r"
                   % (k, v, d.get(k)))

# --- the firmware applies the SAME conversions when it fills the struct -----
# keystep is the one with a multiplier in ripple_config_defaults(); if that
# changes and the host does not follow, the sim and the board diverge.
if "ripple_config.keystep_x100 = RIPPLE_KEYSTEP * 100;" not in src:
    bad.append("ripple_config_defaults() no longer sets keystep_x100 as "
               "RIPPLE_KEYSTEP * 100; firmware_defaults still divides by 100")
for f, macro in (("peak_x100", "RIPPLE_PEAK"),
                 ("falloff_x100", "RIPPLE_FALLOFF")):
    if "ripple_config.%s    = %s;" % (f, macro) not in src.replace("  ", " ") \
       and "%s = %s;" % (f, macro) not in re.sub(r"\s+", " ", src):
        bad.append("%s is no longer taken straight from %s" % (f, macro))

# --- every default the struct needs is actually defined --------------------
for need in ("RIPPLE_BASE_R", "RIPPLE_BASE_G", "RIPPLE_BASE_B", "RIPPLE_HI_R",
             "RIPPLE_HI_G", "RIPPLE_HI_B", "RIPPLE_SPREAD", "RIPPLE_RADIUS",
             "RIPPLE_KEYSTEP", "RIPPLE_PEAK", "RIPPLE_FADE",
             "RIPPLE_FALLOFF"):
    if need not in raw:
        bad.append("%s has no #define in ripple_config.h" % need)

# --- PEAK and FALLOFF are PERCENTS now, not floats -------------------------
# They were 0.33f / 1.0f before the values moved into a fixed-point struct. A
# keymap or header still using a float would compile and render nothing.
for macro in ("RIPPLE_PEAK", "RIPPLE_FALLOFF"):
    if re.search(r"#\s*define\s+%s\s+[0-9.]*[.f]" % macro, hdr):
        bad.append("%s is a float; it must be a percent integer" % macro)

# --- codecs round-trip -----------------------------------------------------
for codec, samples in (("color", ["0000ff", "ff0066", "000000", "ffffff"]),
                       ("pct", ["0.33", "1", "0.01"]),
                       ("x100", ["13", "1.01", "100"]),
                       ("mode", ["flat", "ripple"]),
                       ("int", ["0", "26", "5000"])):
    for s in samples:
        v = qr.encode(codec, s)
        back = qr.decode(codec, v)
        if qr.encode(codec, back) != v:
            bad.append("codec %s: %r -> %r -> %r is not stable"
                       % (codec, s, v, back))

# a colour survives its exact wire form (the off-by-one bug's poster child)
if qr.encode("color", "ff0066") != 0xFF0066:
    bad.append("colour encode is wrong")
if qr.decode("color", 0xFF0066) != "ff0066":
    bad.append("colour decode is wrong")

# bad input is an error, not a silent zero
for codec, junk in (("color", "nope"), ("pct", "banana"), ("mode", "sideways"),
                    ("int", "twelve")):
    try:
        qr.encode(codec, junk)
        bad.append("codec %s accepted %r instead of raising" % (codec, junk))
    except qr.Error:
        pass

if bad:
    for b in bad:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
EOF

pass "header defaults, the x100 conversions, and every codec round-trip"
