# Copyright 2026 jello-d
# SPDX-License-Identifier: Apache-2.0
"""Shared primitives for the qmk-ripple commands.

The package ships TWO commands and this module is the single source of truth
they both read, so a constant (the VID/PID, the udev rule, the wording of the
first-flash warning) is never written down twice:

    bin/qmk-ripple        routine control (off/on/bootloader). Never root.
    bin/qmk-ripple-admin  build/flash/install/check/selftest. Sometimes root.

Nothing here talks to the network or needs a third-party module; it is all
sysfs reads plus a write to a hidraw node.
"""
import glob
import os
import subprocess
import time

# --- the board ---------------------------------------------------------------
VID, PID = 0x359B, 0x0010          # Drop CSTM65
REPORT_LEN = 32                    # QMK RAW_EPSIZE
FF60 = bytes((0x06, 0x60, 0xFF))   # Usage Page 0xFF60 in a report descriptor

# The 1-byte control protocol (see qmk/hostctl.c).
CMDS = {"off": 0x01, "on": 0x02, "bootloader": 0x03}

# --- the udev rule -----------------------------------------------------------
RULE_PATH = "/etc/udev/rules.d/60-qmk-ripple.rules"
RULE_TEXT = """\
# Grant the active-seat user access to the ripple keyboard's raw-HID interface
# (Drop CSTM65, 359b:0010), so qmk-ripple can send backlight off/on without
# root. uaccess = an ACL for the logged-in session user, same mechanism as the
# ddcutil/i2c and input rules. Installed by `qmk-ripple-admin install`.
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="%04x", \
ATTRS{idProduct}=="%04x", TAG+="uaccess"
""" % (VID, PID)

# --- the two warnings every tool has to be able to print ---------------------
# Written ONCE here so the command help, the error paths, and the docs cannot
# drift apart.
FIRST_FLASH_NOTE = """\
These tools drive the keyboard over its 0xFF60 raw-HID interface, which exists
only because the ripple firmware builds with RAW_ENABLE. A board still running
stock firmware has nothing listening, so off/on/bootloader cannot work and the
FIRST flash has to be started by hand:

  1. put the board in its bootloader physically (on the CSTM65: double-tap the
     reset button, so it mounts as a UF2 drive)
  2. qmk-ripple-admin flash --manual

After that first flash the board speaks this protocol and everything else in
the package works, including `flash` with no --manual (it jumps by itself)."""

USAGE_PAGE_WARNING = """\
0xFF60 is the STANDARD QMK raw-HID usage page, not ours: VIA uses it too. Its
presence proves a raw-HID interface exists, NOT that the ripple firmware is
running. The command bytes collide, and not harmlessly -- ripple's 0x03
(bootloader) is VIA's id_set_keyboard_value, a WRITE. So these tools never
send control bytes to a board just because the interface is there; on an
unconfirmed board, flash with --manual instead."""


class Error(Exception):
    """A fatal, already-explained error. Callers print it and exit 1."""


class NotFound(Exception):
    """The keyboard is not on the bus. Callers exit 2 (a benign no-op for
    panel-power, which must treat 'no keyboard' as nothing to do)."""


# --- sysfs helpers -----------------------------------------------------------
def uevent(path):
    """Parse a sysfs uevent file into a dict (missing file -> empty)."""
    d = {}
    try:
        with open(path) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                d[k] = v
    except OSError:
        pass
    return d


def find_node(vid=VID, pid=PID):
    """/dev/hidrawN for the raw-HID (0xFF60) interface of vid:pid, or None.

    Scans sysfs rather than using hidapi, whose Linux backend reports
    usage_page as 0 and so cannot pick the right interface.
    """
    want = "%04X:%08X:%08X" % (0x0003, vid, pid)  # bus:vid:pid in HID_ID
    for sysdir in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        dev = os.path.join(sysdir, "device")
        hid_id = uevent(os.path.join(dev, "uevent")).get("HID_ID", "").upper()
        if hid_id != want:
            continue
        try:
            with open(os.path.join(dev, "report_descriptor"), "rb") as f:
                rd = f.read()
        except OSError:
            continue
        if FF60 in rd:
            return "/dev/" + os.path.basename(sysdir)
    return None


def find_usb_dir(vid=VID, pid=PID):
    """/sys/bus/usb/devices/<n> for the board, or None. Used for the port
    reset and for waiting out a re-enumeration."""
    for d in sorted(glob.glob("/sys/bus/usb/devices/*/")):
        try:
            with open(os.path.join(d, "idVendor")) as f:
                if int(f.read().strip(), 16) != vid:
                    continue
            with open(os.path.join(d, "idProduct")) as f:
                if int(f.read().strip(), 16) != pid:
                    continue
        except (OSError, ValueError):
            continue
        return d.rstrip("/")
    return None


def usb_devnode(sysdir):
    """/dev/bus/usb/BBB/DDD for a /sys/bus/usb/devices/<n> dir."""
    try:
        with open(os.path.join(sysdir, "busnum")) as f:
            bus = int(f.read().strip())
        with open(os.path.join(sysdir, "devnum")) as f:
            dev = int(f.read().strip())
    except (OSError, ValueError) as e:
        raise Error("cannot read busnum/devnum for %s: %s" % (sysdir, e))
    return "/dev/bus/usb/%03d/%03d" % (bus, dev)


def present(vid=VID, pid=PID):
    """True when the board is on the bus in its normal (non-bootloader) mode."""
    return find_usb_dir(vid, pid) is not None


def wait_for(predicate, timeout, interval=1.0):
    """Poll predicate() until true or timeout (seconds). Returns the result."""
    waited = 0.0
    while waited < timeout:
        if predicate():
            return True
        time.sleep(interval)
        waited += interval
    return bool(predicate())


# --- the control protocol ----------------------------------------------------
def send(cmd, vid=VID, pid=PID):
    """Send a 1-byte control command. Raises NotFound / Error.

    Deliberately does NOT probe or identify the firmware first: see
    USAGE_PAGE_WARNING. The caller is asserting this board runs ripple.
    """
    if cmd not in CMDS:
        raise Error("unknown command %r" % cmd)
    node = find_node(vid, pid)
    if node is None:
        raise NotFound("keyboard not found (no 0xFF60 raw-HID interface)")
    report = bytes([0x00, CMDS[cmd]] + [0] * (REPORT_LEN - 1))
    try:
        fd = os.open(node, os.O_WRONLY)
        try:
            os.write(fd, report)
        finally:
            os.close(fd)
    except OSError as e:
        raise Error("%s: %s" % (node, e))
    return node


# --- the UF2 bootloader drive ------------------------------------------------
# This box (and any box with no automount daemon) never mounts the drive for
# us, so the flash path finds the raw block device and mounts it itself.
def find_uf2_dev():
    """/dev/sdX of the tinyuf2 drive, or None.

    Matched on the SCSI model ("Adafruit UF2 Bootloader"), never on a label or
    a guess at the device letter, so no other removable device -- a card
    reader, a stick, the system disk -- can be mistaken for the keyboard.
    """
    for blk in sorted(glob.glob("/sys/block/sd*")):
        try:
            with open(os.path.join(blk, "device", "model")) as f:
                model = f.read().strip()
        except OSError:
            continue
        if "UF2" in model.upper():
            return "/dev/" + os.path.basename(blk)
    return None


def mountpoint(dev):
    """Where dev is mounted, or None."""
    try:
        with open("/proc/mounts") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == dev:
                    return parts[1].replace("\\040", " ")
    except OSError:
        pass
    return None


def udisks_mount(dev, log=lambda _m: None, settle=20, tries=6):
    """Mount dev via udisks, absorbing the enumeration race.

    udisks2 handles the uevent asynchronously, so the device shows up in
    /sys/block a beat before udisks has an object for it and an immediate
    `udisksctl mount` dies with "Error looking up object for device". Wait for
    udisks to see it, then retry the mount.
    """
    for i in range(settle):
        if _run_ok(["udisksctl", "info", "-b", dev]):
            log("udisks saw %s after %ds" % (dev, i))
            break
        time.sleep(1)
    for i in range(tries):
        log("udisksctl mount -b %s (try %d)" % (dev, i + 1))
        p = subprocess.run(["udisksctl", "mount", "-b", dev],
                           capture_output=True, text=True)
        log((p.stdout + p.stderr).strip())
        if p.returncode == 0:
            break
        time.sleep(1)
    return mountpoint(dev)


def _run_ok(argv):
    try:
        return subprocess.run(argv, capture_output=True).returncode == 0
    except OSError:
        return False


def pkg_root():
    """The package checkout root, resolved THROUGH the bin/ symlink that a
    provisioner drops on PATH."""
    return os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
