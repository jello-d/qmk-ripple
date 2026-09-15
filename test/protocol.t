#!/bin/sh
# test/protocol.t - the host and the firmware describe the SAME wire.
#
# THIS IS THE REGRESSION FOR THE WORST BUG THIS PACKAGE HAS SHIPPED. The
# firmware read a SET's argument from REQ_VALUE+1, so every value arrived
# shifted one byte: `set radius 40` stored 0, `set hi ff0066` stored 00ff00,
# and `set radius 999` was ACCEPTED as 3 because the shifted value landed back
# inside the range. Nothing caught it -- identify passed, get passed, `show`
# rendered a clean table, `check` went all-green -- because every one of those
# asked the firmware to describe itself and it answered consistently wrong.
#
# Two copies of one fact cannot be checked by asking one of them. So this pins
# the host's byte offsets and subcommand ids against the C SOURCE, which is the
# other copy. It runs with no hardware: the firmware need not even be flashed.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init protocol

HOSTCTL=$HERE/qmk/hostctl.c
[ -f "$HOSTCTL" ] || fail "missing $HOSTCTL"

py - "$HOSTCTL" <<'EOF' || fail "host and firmware disagree about the wire"
import re, sys
import qmkripple as qr

src = open(sys.argv[1]).read()


def define(name):
    m = re.search(r"^#define\s+%s\s+(\d+)" % name, src, re.M)
    assert m, "no #define %s in hostctl.c" % name
    return int(m.group(1))


def enum(name):
    m = re.search(r"^\s*%s\s*=\s*(0[xX][0-9A-Fa-f]+|\d+)," % name, src, re.M)
    assert m, "no enum %s in hostctl.c" % name
    return int(m.group(1), 0)


bad = []

# --- byte offsets -----------------------------------------------------------
# The host writes the SET argument at index 3 and reads replies at 4/8/12.
# Those are literals in lib/qmkripple.py (set_raw, _u32 callers), so compare
# them against the firmware's named constants.
if define("REQ_VALUE") != 3:
    bad.append("REQ_VALUE is %d; the host writes the argument at 3"
               % define("REQ_VALUE"))
if define("REP_VALUE") != 4:
    bad.append("REP_VALUE is %d; the host reads the value at 4"
               % define("REP_VALUE"))
if define("REP_MIN") != 8:
    bad.append("REP_MIN is %d; the host reads min at 8" % define("REP_MIN"))
if define("REP_MAX") != 12:
    bad.append("REP_MAX is %d; the host reads max at 12" % define("REP_MAX"))
if define("REQ_ID") != 2:
    bad.append("REQ_ID is %d; the host writes the id at 2" % define("REQ_ID"))

# The request and reply shapes DIFFER (the reply inserts a status byte), which
# is exactly what was conflated. Assert the difference still holds, so a future
# "tidy-up" that aligns them has to change this test deliberately.
if define("REQ_VALUE") == define("REP_VALUE"):
    bad.append("REQ_VALUE == REP_VALUE: the shapes were aligned; the host "
               "assumes they differ")

# --- subcommand ids ---------------------------------------------------------
for name, host in (("RIPPLE_SUB_IDENTIFY", qr.SUB_IDENTIFY),
                   ("RIPPLE_SUB_STATUS", qr.SUB_STATUS),
                   ("RIPPLE_SUB_GET", qr.SUB_GET),
                   ("RIPPLE_SUB_SET", qr.SUB_SET),
                   ("RIPPLE_SUB_SAVE", qr.SUB_SAVE),
                   ("RIPPLE_SUB_RESET", qr.SUB_RESET)):
    fw = enum(name)
    if fw != host:
        bad.append("%s: firmware 0x%02x, host 0x%02x" % (name, fw, host))

# --- status codes -----------------------------------------------------------
for name, host in (("RIPPLE_OK", qr.ST_OK),
                   ("RIPPLE_EBADID", qr.ST_EBADID),
                   ("RIPPLE_ERANGE", qr.ST_ERANGE),
                   ("RIPPLE_EBADCMD", qr.ST_EBADCMD)):
    fw = enum(name)
    if fw != host:
        bad.append("%s: firmware 0x%02x, host 0x%02x" % (name, fw, host))

# --- the prefix and the magic ----------------------------------------------
m = re.search(r"#define\s+RIPPLE_PREFIX\s+(0[xX][0-9A-Fa-f]+)", src)
assert m, "no RIPPLE_PREFIX"
if int(m.group(1), 0) != qr.PREFIX:
    bad.append("PREFIX: firmware %s, host 0x%02x" % (m.group(1), qr.PREFIX))

magic = "".join(re.findall(r"#define\s+RIPPLE_MAGIC\d\s+'(.)'", src))
if magic.encode() != qr.MAGIC:
    bad.append("MAGIC: firmware %r, host %r" % (magic, qr.MAGIC.decode()))

# --- the legacy flat bytes --------------------------------------------------
for name, key in (("HOSTCTL_RGB_OFF", "off"), ("HOSTCTL_RGB_ON", "on"),
                  ("HOSTCTL_BOOTLOADER", "bootloader")):
    fw = enum(name)
    if fw != qr.CMDS[key]:
        bad.append("%s: firmware 0x%02x, host 0x%02x"
                   % (name, fw, qr.CMDS[key]))

if bad:
    for b in bad:
        print("  " + b, file=sys.stderr)
    sys.exit(1)
EOF

# --- the encode/decode of a u32 must be symmetric and little-endian ---------
py - <<'EOF' || fail "u32 pack/unpack is not symmetric"
import qmkripple as qr
for v in (0, 1, 40, 999, 0xFF0066, 0xFFFFFF, 0xFFFFFFFF):
    b = bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])
    assert qr._u32(bytes(4) + b, 4) == v, v
# The exact case that shipped wrong: 0xFF0066 little-endian is 66 00 FF 00,
# and reading one byte late yields 0x0000FF00 -> the observed "00ff00".
v = 0xFF0066
b = bytes([0, qr.PREFIX, 0, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, 0])
assert qr._u32(b, 3) == v
assert qr._u32(b, 4) == 0x0000FF00, "the off-by-one no longer reproduces"
EOF

pass "wire offsets, subcommands, status codes and magic all agree"
