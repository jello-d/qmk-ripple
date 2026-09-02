# ripple QMK effect

`rgb_matrix_user.inc` is a custom `RGB_MATRIX_CUSTOM_USER` effect (`RIPPLE`): a
solid base colour with a reactive water-ripple highlight on keypress, rendered
on real hardware. Its `ripple_intensity()` is a verbatim port of
`sim/ripple.py`.

## Wiring it into a keymap

For a keymap dir `<board>/keymaps/ripple/` (base it on the board's `default`):

- **rules.mk**: `RGB_MATRIX_CUSTOM_USER = yes` (and `VIALRGB_ENABLE = yes` etc.
  for the Vial build).
- **config.h**:
  - `#define RGB_MATRIX_KEYREACTIVE_ENABLED` so `g_last_hit_tracker` (the
    keypress positions/ages the effect reads) is populated.
  - `#define RGB_MATRIX_DEFAULT_MODE RGB_MATRIX_CUSTOM_RIPPLE` to boot into it.
  - optionally override any `RIPPLE_*` tunable (colours, spread, radius, fade,
    falloff) to match a re-tuned simulator run.
- **rgb_matrix_user.inc**: symlink or copy this file into the keymap dir (QMK
  auto-includes it by that exact name when the rule above is set).

## Build + flash (CSTM65: STM32F303, tinyuf2)

    qmk-ripple-admin build              # wraps build.sh
    qmk-ripple-admin flash              # jump, mount, copy, verify

Under the hood the board mounts as a UF2 drive and the `.uf2` is copied onto
it. To revert, flash the stock/default `.uf2` the same way -- fully reversible.

**Use `qmk-ripple-admin flash` rather than doing it by hand.** "Drag-and-drop"
assumes a desktop that automounts the drive and that the drive is ready the
moment it appears. Neither held here, and each cost a failed flash:

- **Nothing automounts it.** A box with no automount daemon (no udiskie, gvfs
  or nautilus) leaves the UF2 drive as a bare block device. Waiting for a
  mountpoint waits forever, and the board sits in the bootloader with dead keys
  until it is power-cycled. `flash` finds the raw device and mounts it itself.
- **Find it by SCSI model, not by label or letter.** The tinyuf2 drive reports
  model `Adafruit UF2 Bootloader`; matching that keeps the tool off every other
  removable device.
- **udisks handles the uevent asynchronously.** The device lands in
  `/sys/block` a beat before udisks has an object for it, so mounting the
  instant it appears fails with `Error looking up object for device`. `flash`
  waits for udisks to see it, then retries.
- **I/O errors during the copy are the success path.** The board reboots itself
  the moment the image lands, so the host's queued writes hit a device that is
  already gone (`device offline error`, `FAT-fs ... unable to read`). The
  verdict is whether the keyboard re-enumerates, not whether `cp` was quiet.

A failed flash never writes anything, so the old firmware is always intact.
`flash` detects a board already sitting in its bootloader and skips the jump,
so the recovery from any failure is to re-run it -- no power cycle needed.

### First-flash notes (learned the hard way)

- **The first flash needs a human.** `flash` asks the board to jump over raw
  HID, which only the ripple firmware answers. A board that does not have it
  yet cannot be asked, so the one-time path is `qmk-ripple-bootstrap`: it
  prompts you to double-tap reset, waits for the UF2 drive, then flashes.
- **A bare `bootloader_jump()` skips the shutdown hooks.** The red indicator is
  painted by `shutdown_user`, which QMK runs from `shutdown_quantum()` --
  reached via `reset_keyboard()`, *not* by calling `bootloader_jump()`
  directly. Getting this wrong put the board in the flasher with the keys still
  blue. `reset_keyboard()` also waits 250ms, which is what gives the IS31FL3733
  time to latch the colour so it survives into the bootloader.

- **Two bootloader modes.** Double-tap reset should give the tinyuf2 USB *drive*
  (drag-and-drop). But a BOOT0-style entry lands in the STM32 ROM **DFU**
  bootloader (`0483:df11`, no drive) instead. DFU is fine to flash from -- the
  app is confined to `0x08004000+`, above tinyuf2 (`0x08000000-0x08003FFF`), so
  flashing only the app region preserves the bootloader (never a brick):

      # extract the app region from the .uf2, then:
      dfu-util -a 0 -s 0x08004000:leave -D app.bin

  (dfu-util here has device access without sudo.)
- **Clear EEPROM after the first flash.** The CSTM65's stock (Drop) firmware is
  QMK-based, so its saved EEPROM is compatible enough that a fresh QMK build
  *loads the old RGB config* instead of applying `RGB_MATRIX_DEFAULT_MODE`. The
  symptom: a solid leftover colour (e.g. magenta), no ripple. Fix: `EE_CLR`
  (default keymap: hold `MO(1)` = the key right of right-Alt, press Space) to
  reset to the boot default, then the ripple effect appears.

## Tunables

The effect no longer reads `#define`s directly. They are the boot DEFAULTS for
`ripple_config` (see `ripple_config.h`), which the effect renders from and the
host retunes at runtime, so `RIPPLE_BASE_{R,G,B}`, `RIPPLE_HI_{R,G,B}`,
`RIPPLE_SPREAD`, `RIPPLE_RADIUS`, `RIPPLE_KEYSTEP`, `RIPPLE_PEAK`,
`RIPPLE_FADE` and `RIPPLE_FALLOFF` still set the look from a keymap's
`config.h` exactly as before.

What changed is that tuning them no longer needs a reflash:

    qmk-ripple show
    qmk-ripple set hi ff0066
    qmk-ripple save

`RIPPLE_PEAK` and `RIPPLE_FALLOFF` are now PERCENTS (33, 100) rather than
floats (0.33f, 1.0f), and `RIPPLE_KEYSTEP` is a whole number of grid units,
because the values live in a fixed-point struct that has to survive EEPROM.
An old keymap that set them as floats needs those three updated.
