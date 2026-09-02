# qmk-ripple

A custom QMK RGB-matrix keyboard effect plus its host control, built for the
Drop CSTM65 but portable to any QMK board with a per-key RGB matrix.

The **ripple** effect: a steady solid base colour (blue) with a reactive
water-ripple highlight on keypress -- the pressed key snaps to a second colour
(purple) at full brightness, and a delayed, fainter ring blooms on the
surrounding keys, all blending back to the base as it fades. Brightness stays
constant; the fade is a colour blend, not a dim.

Built because the CSTM65's stock firmware has no host-controllable RGB and no
"base + second colour" reactive effect. The CSTM65 port lives upstream (QMK and
vial-qmk `keyboards/drop/cstm65`: STM32F303, IS31FL3733, tinyuf2 bootloader ->
drag-and-drop `.uf2`), so none of this depends on the vendor.

## Layout

    bin/qmk-ripple        routine control (off/on only); never root
    bin/qmk-ripple-admin  build/flash/install/check/selftest; sometimes root
    lib/qmkripple.py      shared constants + device discovery for both
    qmk/                the firmware: custom effect, host-control, keymap, build
    sim/                terminal simulator for tuning the effect
    leds/               per-keyboard LED position tables (QMK coord space)

## Two commands, split by blast radius

`bin/qmk-ripple` is the hot path: a screen-power daemon (e.g. `panel-power`)
runs it on every blank and unblank, so it is small, dependency-free, and has no
privileged code in it at all.

    qmk-ripple off          LEDs dark (transient; see below)
    qmk-ripple on           LEDs back

That is the whole surface. The bootloader jump is NOT here: it is a flashing
operation, and its byte has teeth (see the collision table below), so the
command that runs on every screen blank must not be able to send it.

`bin/qmk-ripple-admin` is the rare half, allowed to be slow, chatty and
privileged:

    qmk-ripple-admin build [BOARD] [KEYMAP]  compile the firmware
    qmk-ripple-admin flash [FILE]            flash it (--manual for the first)
    qmk-ripple-admin bootloader              jump to the flasher, no flash
    qmk-ripple-admin install                 udev access rule (sudo)
    qmk-ripple-admin check                   audit ([OK]/[WARN]/[FAIL] + code)
    qmk-ripple-admin selftest                prove the relight works (sudo)

`install` grants the session user the raw-HID node via a udev `uaccess` rule
(it is root-only otherwise), which is why routine control needs no root.

`off` is **transient**: it lives in the MCU's RAM
(`rgb_matrix_disable_noeeprom`) and the firmware wipes it on any fresh USB
enumeration, so a reboot or replug always comes back lit even if nothing ever
sends `on`. That matters because a reboot is *not* a power cycle for a USB
port: the port holds 5V, the MCU never resets, and an earlier version of this
firmware came back dark with the session that owed it an `on` long gone.

## First flash (bootstrap)

**Most of this package only works after the first flash.** `off`, `on` and
the bootloader jump all speak the 0xFF60 raw-HID interface, which exists only
because the ripple firmware builds with `RAW_ENABLE`. A board on stock
firmware has nothing listening, so the first flash must be started by hand:

    qmk-ripple-admin build                 # compile
    # put the board in its bootloader physically:
    #   Drop CSTM65: double-tap the reset button (it mounts as a UF2 drive)
    qmk-ripple-admin flash --manual        # waits for the drive, copies

After that the board speaks the protocol and `flash` needs no `--manual` -- it
jumps by itself.

### 0xFF60 does not prove ripple is installed

0xFF60 is the *standard* QMK raw-HID usage page; VIA uses it too. So finding
that interface proves only that some raw-HID firmware is answering. The command
bytes collide, and not harmlessly:

| byte | ripple | VIA (`quantum/via.h`) |
|------|--------|------------------------|
| 0x01 | off | `id_get_protocol_version` (read) |
| 0x02 | on | `id_get_keyboard_value` (read) |
| 0x03 | bootloader | `id_set_keyboard_value` (**a write**) |

So the tools never send control bytes to a board just because the interface is
there, and `check` reports what it can prove rather than claiming ripple is
running. On an unconfirmed board, flash with `--manual`.

## Firmware (`qmk/`)

`qmk/rgb_matrix_user.inc` is the custom `RGB_MATRIX_CUSTOM_USER` effect;
`qmk/hostctl.c` adds the raw-HID commands and a red bootloader indicator.
`qmk/build.sh` assembles a keymap onto a (vial-)qmk tree and compiles it. See
`qmk/README.md` for wiring, build, and the flashing notes (DFU vs UF2, and the
EE_CLR-after-first-flash gotcha).

    qmk-ripple-admin build              # or, directly:
    VIAL_QMK=~/src/vial-qmk sh qmk/build.sh drop/cstm65 ripple

Then `qmk-ripple-admin flash` (add `--manual` for a board that does not run
this firmware yet). Prefer it over copying the `.uf2` by hand: the drive does
not automount on a box with no automount daemon, and mounting it the instant
it appears races udisks. `flash` handles both.

## Simulator (`sim/ripple.py`)

Dependency-free 24-bit-colour terminal render against the real LED layout, so
the look is tuned with zero flashing. `ripple_intensity()` is the reference the
firmware effect ports verbatim -- tune here, then mirror the constants.

    python3 sim/ripple.py            # demo: auto-typing (Ctrl-C quits)
    python3 sim/ripple.py --keys     # interactive; Tab blanks (screen-off)

Tunables (`--help`): `--base`/`--hi` colours, `--spread` (ms delay per grid
unit), `--radius`/`--keystep` (reach and per-key spacing), `--peak` (first-ring
peak blend; halves outward), `--fade` (blend-back ms), `--falloff`, `--value`.

## Install

Standalone: `qmk-ripple-admin install` (once, for the udev rule); put `bin/` on
PATH. As a managed package: a provisioner clones this repo and symlinks every
`bin/*` into `~/.local/bin`, then runs `qmk-ripple-admin install` for the rule.

`bin/` and `lib/` must stay siblings in the checkout: both commands locate
`lib/qmkripple.py` by resolving their own path *through* the PATH symlink, and
say so loudly if it is missing.

Anything calling this package needs a PATH that includes `~/.local/bin`. A
caller exec'd from a minimal environment (a compositor's lock hook, say) may
not have it, and the failure is silent -- `command -v qmk-ripple` simply finds
nothing and the blank skips the keyboard.

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks
