# ripple

A portable QMK RGB-matrix effect: a steady solid base colour with a reactive,
water-ripple highlight on keypress (bright at the pressed key, then a delayed,
dimmer ring on the neighbours). Plus a host **simulator** so the look is tuned
in the terminal before any firmware is flashed.

Built because Drop's stock CSTM65 firmware has no host-controllable RGB and no
"base + second colour" reactive effect. The CSTM65 port lives upstream (QMK and
vial-qmk `keyboards/drop/cstm65`, STM32F303, IS31FL3733, tinyuf2 bootloader ->
drag-and-drop `.uf2` flashing), so none of this depends on Drop.

## Simulator

Dependency-free, 24-bit-colour terminal render against the real CSTM65 LED
layout (`leds/cstm65.json`, QMK's 0..224 x 0..64 grid).

    python3 sim/ripple.py            # demo: auto-typing animation (Ctrl-C quits)
    python3 sim/ripple.py --keys     # interactive: your keypresses drive it
    python3 sim/ripple.py --once     # one sample frame (headless sanity check)

Tunables (all `--flags`, see `--help`): `--base`/`--hi` colours, `--spread` (ms
of ripple delay per grid unit), `--radius` (reach in units, ~15/key), `--fade`
(ms lit after the wave arrives), `--falloff` (distance dimming curve), `--fps`.

`ripple_intensity()` in `sim/ripple.py` is the **reference implementation** --
the QMK custom effect ports it verbatim, so tune here first.

## Roadmap

- [x] Host simulator (tune the look).
- [ ] QMK custom effect (`RGB_MATRIX_CUSTOM_USER`) in a shared userspace, math
      ported from `ripple_intensity()`; runtime colours via Vial/VialRGB.
- [ ] Build on `vial-qmk` `drop/cstm65` (add a `vial` keymap), flash via UF2.
- [ ] Host screen-off integration: VialRGB/OpenRGB brightness toggle wired into
      the `panel-power` `peripherals` hook (lives in the tackup tree, not here).

## Layout

    leds/        per-keyboard LED position tables (QMK coord space)
    sim/         the terminal simulator
