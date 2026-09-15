#!/bin/sh
# test/params.t - the parameter table exists in FOUR places. Pin them equal.
#
#   qmk/ripple_config.h   enum ripple_param      the ids, canonical
#   qmk/hostctl.c         ripple_params[]        id -> min/max, and the
#                                                get/set switch arms
#   lib/qmkripple.py      PARAMS + PARAM_HELP    name <-> id, and the codec
#   sim/ripple.py         --flags                the same knobs, offline
#
# Adding a tunable means touching all four, and forgetting one fails QUIETLY in
# a different way each time: no range entry makes GET answer EBADID for a
# parameter that exists; no switch arm makes SET silently do nothing and read
# back the old value; no host entry makes it unreachable; no sim flag makes the
# simulator and the board disagree about the effect.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init params

py - "$HERE" <<'EOF' || fail "the parameter table has drifted between copies"
import re, sys
import qmkripple as qr

root = sys.argv[1]
hdr = open(root + "/qmk/ripple_config.h").read()
src = open(root + "/qmk/hostctl.c").read()
sim = open(root + "/sim/ripple.py").read()

# --- canonical: the enum in the header -------------------------------------
enum_body = re.search(r"enum ripple_param \{(.*?)\};", hdr, re.S)
assert enum_body, "no enum ripple_param in ripple_config.h"
fw_ids = {}
for name, val in re.findall(r"(RIPPLE_P_[A-Z_]+)\s*=\s*(0[xX][0-9A-Fa-f]+)",
                            enum_body.group(1)):
    fw_ids[name] = int(val, 0)
assert fw_ids, "parsed no ids out of enum ripple_param"

bad = []

# --- host PARAMS must match the enum exactly, both ways ---------------------
host_ids = {"RIPPLE_P_" + n.upper(): i for n, i, _c in qr.PARAMS}
for k in sorted(set(fw_ids) | set(host_ids)):
    f, h = fw_ids.get(k), host_ids.get(k)
    if f is None:
        bad.append("%s is in the host PARAMS but not in enum ripple_param" % k)
    elif h is None:
        bad.append("%s is in enum ripple_param but the host cannot reach it"
                   % k)
    elif f != h:
        bad.append("%s: firmware 0x%02x, host 0x%02x" % (k, f, h))

# --- every id needs a RANGE row, or GET answers EBADID for a real parameter -
meta = re.search(r"ripple_params\[\] = \{(.*?)\};", src, re.S)
assert meta, "no ripple_params[] table in hostctl.c"
ranged = set(re.findall(r"\{(RIPPLE_P_[A-Z_]+),", meta.group(1)))
for k in sorted(set(fw_ids) - ranged):
    bad.append("%s has no row in ripple_params[]: GET would answer EBADID "
               "for a parameter that exists" % k)

# --- every id needs a get AND a set arm, or SET silently does nothing -------
get_body = re.search(r"static uint32_t ripple_get\(uint8_t id\) \{(.*?)\n\}",
                     src, re.S)
set_body = re.search(r"static void ripple_set\(uint8_t id, uint32_t v\) \{"
                     r"(.*?)\n\}", src, re.S)
assert get_body and set_body, "could not find ripple_get/ripple_set"
for k in sorted(fw_ids):
    if ("case %s:" % k) not in get_body.group(1):
        bad.append("%s has no arm in ripple_get(): reads back 0" % k)
    if ("case %s:" % k) not in set_body.group(1):
        bad.append("%s has no arm in ripple_set(): writes are silently "
                   "dropped" % k)

# --- host-side completeness -------------------------------------------------
for name, _i, codec in qr.PARAMS:
    if name not in qr.PARAM_HELP:
        bad.append("%s has no PARAM_HELP, so `show` prints a blank meaning"
                   % name)
    if codec not in ("color", "pct", "x100", "mode", "int"):
        bad.append("%s has unknown codec %r" % (name, codec))

# --- the simulator exposes the same knobs ----------------------------------
sim_flags = set(re.findall(r'add_argument\("--([a-z0-9-]+)"', sim))
for name, _i, _c in qr.PARAMS:
    if name not in sim_flags:
        bad.append("sim/ripple.py has no --%s flag: the simulator and the "
                   "board would disagree about that knob" % name)

if bad:
    for b in bad:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
print("  %d parameters agree across header, firmware, host and sim"
      % len(fw_ids))
EOF

pass "ids, ranges, get/set arms, help text and sim flags all line up"
