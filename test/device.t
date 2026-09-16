#!/bin/sh
# test/device.t - device SELECTION, against a fixture sysfs tree.
#
# This is the most destructive decision the package makes. find_uf2_dev picks
# the block device that `flash` then writes firmware onto; a false positive
# writes it to the wrong disk. The box it runs on has an SSD and an SD/MMC card
# reader sitting next to the keyboard's bootloader drive, and the matching has
# never been exercised anywhere but by eye.
#
# find_node is the same shape one layer over: 0xFF60 is the SHARED QMK/VIA
# usage page, so picking by vid:pid alone would hand control bytes to whatever
# else answered -- and ripple's 0x03 is a WRITE on a VIA board.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init device

# Point the lib at the fixture trees. Exported, not passed, because each py
# call below re-imports the module and reads them at import time.
QMKRIPPLE_SYS_BLOCK=$T/block
QMKRIPPLE_SYS_HIDRAW=$T/hidraw
export QMKRIPPLE_SYS_BLOCK QMKRIPPLE_SYS_HIDRAW

# --- fixture: a UF2 drive among realistic decoys ---------------------------
B=$T/block
mk_blk() {   # <name> <vendor> <model>
  mkdir -p "$B/$1/device"
  printf '%s\n' "$2" > "$B/$1/device/vendor"
  printf '%s\n' "$3" > "$B/$1/device/model"
}
mk_blk sda "ATA"      "SAMSUNG PM881 SA"
mk_blk sdb "Generic-" "SD/MMC CRW"
mk_blk sdc "Adafruit" "UF2 Bootloader"

py - <<'EOF' || fail "block-device selection is wrong"
import os, sys
import qmkripple as qr
got = qr.find_uf2_dev()
assert got == "/dev/sdc", (
    "picked %r; the SSD and the card reader are decoys" % got)
EOF

# --- no UF2 drive: must pick NOTHING, not "the first disk" ----------------
rm -rf "$B/sdc"
py - <<'EOF' || fail "found a UF2 drive when none is present"
import qmkripple as qr
got = qr.find_uf2_dev()
assert got is None, "matched %r with no UF2 device attached" % got
EOF

# --- a decoy that merely CONTAINS the letters must not match loosely ------
# "uf2" lowercase in a vendor string, say, or a model that happens to include
# it as part of another word. The match is on the model and upper-cased, so
# pin the two that must NOT match alongside the one that must.
mk_blk sdd "ACME" "SUPERUF2000 DISK"
py - <<'EOF' || fail "matching is too loose or too tight"
import qmkripple as qr
# This DOES contain UF2 and matches. That is accepted behaviour, pinned so a
# silent change to the rule fails loudly: the consequence is writing firmware
# onto someone's disk.
got = qr.find_uf2_dev()
assert got == "/dev/sdd", "expected the UF2-named decoy to match (%r)" % got
EOF
rm -rf "$B/sdd"

# --- hidraw: the right interface, not merely the right board --------------
H=$T/hidraw
# Octal escapes: \ooo is the POSIX-guaranteed form for printf. \x happens to
# work in the shells here, but it is an extension, and a fixture that silently
# contains TEXT instead of BYTES makes this test fail for the wrong reason.
mk_hid() {   # <name> <hid_id> <descriptor-bytes, octal escapes>
  mkdir -p "$H/$1/device"
  printf 'HID_ID=%s\n' "$2" > "$H/$1/device/uevent"
  printf "$3" > "$H/$1/device/report_descriptor"
}
# hidraw0: our board, but the KEYBOARD interface (no 0xFF60 in its descriptor)
mk_hid hidraw0 "0003:0000359B:00000010" '\005\001\011\006'
# hidraw1: a DIFFERENT board that does expose 0xFF60
mk_hid hidraw1 "0003:0000FEED:00000001" '\006\140\377'
# hidraw2: our board, the raw-HID interface
mk_hid hidraw2 "0003:0000359B:00000010" '\006\140\377\011\141'

py - <<'EOF' || fail "hidraw interface selection is wrong"
import qmkripple as qr
got = qr.find_node()
assert got == "/dev/hidraw2", (
    "picked %r: it must be OUR vid:pid AND the 0xFF60 interface, not the "
    "board's keyboard interface and not another vendor's raw-HID" % got)
# A vid:pid nothing matches finds nothing, rather than falling back.
assert qr.find_node(0xDEAD, 0xBEEF) is None
EOF

# --- our board present but with NO 0xFF60 interface = stock firmware -------
rm -rf "$H/hidraw2"
py - <<'EOF' || fail "a stock board should look like 'no raw-HID', not a match"
import qmkripple as qr
assert qr.find_node() is None, (
    "matched the keyboard interface of a board with no raw-HID; the tools "
    "would then send control bytes to it")
EOF

pass "UF2 drive and hidraw interface picked correctly among decoys"
