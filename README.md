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

    bin/qmk-ripple            control + tuning (off/on, mode, set); no root
    bin/qmk-ripple-admin      build/flash/install/check; sometimes root
    bin/qmk-ripple-bootstrap  one-time setup for a virgin board
    lib/qmkripple.py          shared constants + discovery for all three
    qmk/                the firmware: custom effect, host-control, keymap, build
    sim/                terminal simulator for tuning the effect
    leds/               per-keyboard LED position tables (QMK coord space)

## Three commands, split by blast radius

`bin/qmk-ripple` is the hot path: a screen-power daemon (e.g. `panel-power`)
runs it on every blank and unblank, so it is small, dependency-free, and has no
privileged code in it at all.

    qmk-ripple off | on              backlight (transient; see below)
    qmk-ripple mode flat | ripple    plain colour, or the reactive effect
    qmk-ripple show                  every parameter, with its range
    qmk-ripple get NAME
    qmk-ripple set NAME VALUE        live, RAM only
    qmk-ripple save                  commit the current values to EEPROM
    qmk-ripple reset                 back to the compiled-in defaults

The bootloader jump is NOT here: it is a flashing operation, and its byte has
teeth (see the collision table below), so the command that runs on every
screen blank must not be able to send it.

`bin/qmk-ripple-admin` is the rare half, allowed to be slow, chatty and
privileged:

    qmk-ripple-admin build [BOARD] [KEYMAP]  compile the firmware
    qmk-ripple-admin flash [FILE]            flash an update
    qmk-ripple-admin bootloader              jump to the flasher, no flash
    qmk-ripple-admin install                 udev access rule (sudo)
    qmk-ripple-admin check                   audit ([OK]/[WARN]/[FAIL] + code)
    qmk-ripple-admin selftest                round-trip + relight test (sudo)

`install` grants the session user the raw-HID node via a udev `uaccess` rule
(it is root-only otherwise), which is why routine control needs no root.

`bin/qmk-ripple-bootstrap` runs **once per physical keyboard** and then never
again. It is separate because it is the only part of the package that needs a
human to touch the hardware, and folding it into `flash` gave that command a
mode it needed exactly once:

    qmk-ripple-bootstrap          guided: install, build, flash, verify
    qmk-ripple-bootstrap --check  what state is this board in? (no changes)

Both other commands assume the firmware is already there and say so plainly
when it is not, rather than half-working.

`off` is **transient**: it lives in the MCU's RAM
(`rgb_matrix_disable_noeeprom`) and the firmware wipes it on any fresh USB
enumeration, so a reboot or replug always comes back lit even if nothing ever
sends `on`. That matters because a reboot is *not* a power cycle for a USB
port: the port holds 5V, the MCU never resets, and an earlier version of this
firmware came back dark with the session that owed it an `on` long gone.

## Tuning

Every knob the effect has is settable at runtime, so retuning the look needs
no reflash:

    qmk-ripple show
    PARAM     VALUE        RANGE              MEANING
    base      0000ff       000000 .. ffffff   steady base colour (hex rrggbb)
    hi        9400d3       000000 .. ffffff   ripple highlight colour
    spread    5            0 .. 1000          ms of delay per grid unit
    radius    26           0 .. 255           reach in grid units
    peak      0.33         0.01 .. 1          first-ring blend (halves out)
    fade      216          1 .. 5000          ms to blend back to base
    falloff   1            0.01 .. 10         time curve; >1 lingers
    keystep   13           1 .. 100           grid units per key
    mode      ripple       flat | ripple      plain colour, or reactive

A `set` is **transient**: it lands in RAM only, so sweeping a value costs no
flash wear and an experiment you dislike dies at the next power cycle. `save`
commits the current values to EEPROM; `reset` restores the compiled-in
defaults to RAM, and persisting that is another deliberate `save`.

    qmk-ripple set hi ff0066      # live, try it
    qmk-ripple set radius 40
    qmk-ripple save               # keep it
    qmk-ripple mode flat          # ripple off: just the base colour

Ranges are reported BY the firmware with every `get`, so the host never
carries a second copy that could drift. An out-of-range value is refused, not
silently clamped -- a quietly adjusted value would be a lie about what was
asked for.

## First flash (bootstrap)

**Most of this package only works after the first flash.** `off`, `on` and
the bootloader jump all speak the 0xFF60 raw-HID interface, which exists only
because the ripple firmware builds with `RAW_ENABLE`. A board on stock
firmware has nothing listening, so the first flash must be started by hand:

    qmk-ripple-bootstrap

It installs the udev rule, builds, tells you to double-tap the reset button,
waits for the UF2 drive, flashes, and verifies the board answers as ripple
firmware. After that the board speaks the protocol and every other command
works, including `qmk-ripple-admin flash`, which drives the jump itself.

The hands-on step is unavoidable, not a missing feature: a board with no
raw-HID interface cannot be *asked* to enter its bootloader, so the one flash
that matters most is the one no tool can start.

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
there. On an unconfirmed board, use `qmk-ripple-bootstrap`.

Everything added after those three bytes is namespaced behind a `0x52` prefix,
which VIA does not define: a v2 command aimed at a VIA board lands in its
`id_unhandled` branch and does nothing. That is also what makes identification
trustworthy -- only this firmware answers `0x52 0x00` with the magic `RPL`, so
`qmk-ripple-admin check` can positively confirm the firmware instead of
guessing from the presence of an interface:

    [OK]   ripple firmware confirmed (protocol v1, config v1, 9 params)

An older ripple build echoes the command back without the magic, so it is
distinguishable from a current one rather than being mistaken for it.

## Firmware (`qmk/`)

`qmk/rgb_matrix_user.inc` is the custom `RGB_MATRIX_CUSTOM_USER` effect;
`qmk/hostctl.c` adds the raw-HID commands and a red bootloader indicator.
`qmk/build.sh` assembles a keymap onto a (vial-)qmk tree and compiles it. See
`qmk/README.md` for wiring, build, and the flashing notes (DFU vs UF2, and the
EE_CLR-after-first-flash gotcha).

    qmk-ripple-admin build              # or, directly:
    VIAL_QMK=~/src/vial-qmk sh qmk/build.sh drop/cstm65 ripple

Then `qmk-ripple-admin flash` (or `qmk-ripple-bootstrap` for a board that
does not run this firmware yet). Prefer either over copying the `.uf2` by
hand: the drive does not automount on a box with no automount daemon, and
mounting it the instant it appears races udisks. Both handle that.

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
