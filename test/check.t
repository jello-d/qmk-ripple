#!/bin/sh
# test/check.t - `qmk-ripple-admin check` and its exit code, with no hardware.
#
# WHY THIS EXISTS. `check` is the one command a PROVISIONER branches on, so its
# exit code is a contract: non-zero means drift a human must fix. Nothing in the
# suite reached it. The whole function needed a board, so every branch was only
# ever exercised by hand on a machine that happened to be healthy -- which is
# the branch that cannot regress. The FAIL paths, the ones that matter, were
# untested.
#
# It is testable now because do_check was split into one helper per audit
# (f41f487 left it at 59 lines doing four unrelated things). Each helper is
# callable on its own, so the drift paths can be driven directly instead of by
# arranging a broken keyboard.
#
# WHAT IS PINNED: a WARN must NOT fail the command and a FAIL must. That
# distinction is the contract, and getting it backwards either fails a
# provisioner on a box with no keyboard attached, or silently passes a board
# whose udev rule never landed.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init check

py - "$HERE" "$T" <<'EOF' || fail "check's audits or its exit code have drifted"
import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader

root = sys.argv[1]
path = os.path.join(root, "bin", "qmk-ripple-admin")
ld = SourceFileLoader("admin", path)
spec = importlib.util.spec_from_file_location("admin", path, loader=ld)
adm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adm)
qr = adm.qr

bad = []
out = []
adm.say = lambda msg="": out.append(msg)


def run(fn, *a):
  del out[:]
  rc = fn(*a)
  return rc, "\n".join(out)


# --- the udev rule: the one arm that is pure file state --------------------
tmp = sys.argv[2]
rule = os.path.join(tmp, "rule")

qr.RULE_PATH = rule                      # absent
rc, txt = run(adm._check_udev)
if rc != 1:
  bad.append("a MISSING udev rule returned %r, not 1: `check` would exit 0 "
             "and a provisioner would call the box healthy" % rc)
if "[FAIL]" not in txt:
  bad.append("a missing udev rule did not print [FAIL]: %r" % txt)

with open(rule, "w") as f:                # present but STALE
  f.write("something else entirely\n")
rc, txt = run(adm._check_udev)
if rc != 1:
  bad.append("a STALE udev rule returned %r, not 1. Existence is not the "
             "check; the CONTENT is, or an old rule passes forever" % rc)

with open(rule, "w") as f:                # present and current
  f.write(qr.RULE_TEXT)
rc, txt = run(adm._check_udev)
if rc != 0:
  bad.append("a CURRENT udev rule returned %r, not 0" % rc)
if "[OK]" not in txt:
  bad.append("a current udev rule did not print [OK]: %r" % txt)

# --- the raw-HID node: present-but-unwritable is the FAIL, absent is a WARN
# This is the distinction a provisioner lives on. "No keyboard attached" is a
# legitimate state and must exit 0; "the node is there and we cannot write to
# it" means the udev rule never took effect and a human must relogin.
node = os.path.join(tmp, "hidraw9")
open(node, "w").close()

qr.find_node = lambda *a, **k: None
rc, txt = run(adm._check_raw_hid, None)   # no board at all
if rc != 0:
  bad.append("no keyboard attached returned %r, not 0. That is a WARN, not "
             "drift, or every box without the board fails provisioning" % rc)
if "[FAIL]" in txt:
  bad.append("no keyboard attached printed [FAIL]: %r" % txt)

rc, txt = run(adm._check_raw_hid, "/sys/bus/usb/devices/1-1")
if "bootstrap" not in txt:
  bad.append("a board PRESENT with no raw-HID interface should point at "
             "qmk-ripple-bootstrap (it is stock firmware); got %r" % txt)

os.chmod(node, 0o444)
qr.find_node = lambda *a, **k: node
rc, txt = run(adm._check_raw_hid, "/sys/bus/usb/devices/1-1")
if rc != 1:
  bad.append("an UNWRITABLE raw-HID node returned %r, not 1. That is the "
             "udev-rule-not-in-effect case and it must fail" % rc)
if "[FAIL]" not in txt:
  bad.append("an unwritable node did not print [FAIL]: %r" % txt)

# --- and do_check COMBINES them: any FAIL wins, a WARN never does ----------
# EVERY failing arm needs its own case here. Checking only one of them left a
# hole that a mutation found: dropping `rc = 1` from the raw-HID call is a
# one-line edit, and with just the udev case below this file still passed.
with open(rule, "w") as f:
  f.write(qr.RULE_TEXT)
qr.RULE_PATH = rule
qr.find_usb_dir = lambda *a, **k: None
qr.find_uf2_dev = lambda *a, **k: None
qr.find_node = lambda *a, **k: None
rc, txt = run(adm.do_check)               # healthy rule, no board
if rc != 0:
  bad.append("do_check returned %r with a good rule and no board; a box with "
             "the keyboard unplugged is not drift" % rc)

qr.RULE_PATH = os.path.join(tmp, "nope")  # the UDEV arm fails
rc, txt = run(adm.do_check)
if rc != 1:
  bad.append("do_check returned %r when the udev rule was missing; one FAIL "
             "must carry to the exit code" % rc)

qr.RULE_PATH = rule                       # the RAW-HID arm fails, alone
qr.find_usb_dir = lambda *a, **k: "/sys/bus/usb/devices/1-1"
qr.find_node = lambda *a, **k: node        # still mode 0444
rc, txt = run(adm.do_check)
if rc != 1:
  bad.append("do_check returned %r with a good udev rule but an UNWRITABLE "
             "raw-HID node; that arm's failure is being dropped, so a board "
             "the user cannot drive reports healthy" % rc)

if bad:
  for b in bad:
    print("  " + b, file=sys.stderr)
  sys.exit(1)
print("  udev/raw-HID audits and the WARN-vs-FAIL exit contract hold")
EOF

pass "check's audits, and that a WARN does not fail while a FAIL does"
