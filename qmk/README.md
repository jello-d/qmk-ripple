# ripple QMK effect

`rgb_matrix_user.inc` is a custom `RGB_MATRIX_CUSTOM_USER` effect (`RIPPLE`) that
renders the simulator's look on real hardware: a solid base colour with a
reactive water-ripple highlight on keypress. Its `ripple_intensity()` is a
verbatim port of `sim/ripple.py`.

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

    qmk compile -kb drop/cstm65 -km ripple      # -> .build/drop_cstm65_ripple.uf2

Flash is drag-and-drop: double-tap reset (or the `QK_BOOT` key on layer 1) so the
board mounts as a USB drive, then copy the `.uf2` onto it. To revert, flash the
stock/default `.uf2` the same way -- fully reversible.

## Tunables

The effect reads `RIPPLE_BASE_{R,G,B}`, `RIPPLE_HI_{R,G,B}`, `RIPPLE_SPREAD`,
`RIPPLE_RADIUS`, `RIPPLE_FADE`, `RIPPLE_FALLOFF` -- all `#define`-overridable from
the keymap's `config.h`, defaulting to the simulator's v1 values. Runtime colour
control (via Vial/VialRGB) is a later step.
