# kb-qmk-ripple

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

    bin/kb-qmk-ripple   host control command (off/on/bootloader/install/check)
    qmk/                the firmware: custom effect, host-control, keymap, build
    sim/                terminal simulator for tuning the effect
    leds/               per-keyboard LED position tables (QMK coord space)

## Host control (`bin/kb-qmk-ripple`)

Installed on PATH (see Install). Talks a 1-byte raw-HID protocol to the
keyboard's firmware:

    kb-qmk-ripple off          LEDs dark   (transient; a power cycle restores)
    kb-qmk-ripple on           LEDs back
    kb-qmk-ripple bootloader   jump to the flasher (reflash with no reset pin)
    kb-qmk-ripple install      install the raw-HID udev access rule (sudo)
    kb-qmk-ripple check        audit the install ([OK]/[FAIL] + exit code)

`off`/`on` are the hook a screen-power daemon (e.g. `panel-power`) calls so the
keyboard sleeps with the display. `install` grants the session user access to
the raw-HID node via a udev `uaccess` rule (the node is root-only otherwise).

## Firmware (`qmk/`)

`qmk/rgb_matrix_user.inc` is the custom `RGB_MATRIX_CUSTOM_USER` effect;
`qmk/hostctl.c` adds the raw-HID commands and a red bootloader indicator.
`qmk/build.sh` assembles a keymap onto a (vial-)qmk tree and compiles it. See
`qmk/README.md` for wiring, build, and the flashing notes (DFU vs UF2, and the
EE_CLR-after-first-flash gotcha).

    VIAL_QMK=~/src/vial-qmk sh qmk/build.sh drop/cstm65 ripple

Then `kb-qmk-ripple bootloader` (or a reset) and copy the `.uf2` onto the drive.

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

Standalone: `kb-qmk-ripple install` (once, for the udev rule); put `bin/` on
PATH. As a managed package: a provisioner clones this repo and symlinks `bin/`
into `~/.local/bin`, then runs `kb-qmk-ripple install` for the rule.
