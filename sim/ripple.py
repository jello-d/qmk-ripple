#!/usr/bin/env python3
"""ripple -- host simulator for the "solid base + reactive ripple" RGB effect.

Renders the effect in the terminal (24-bit colour) against a real keyboard's LED
layout, driven by synthetic or live keypresses, so the look can be tuned with
zero flashing. The intensity math in ripple_intensity() is the REFERENCE for the
QMK port -- keep it and the QMK custom effect in lockstep.

Model (matches QMK's rgb_matrix reactive framework):
  - coordinates are QMK's 0..224 (x) by 0..64 (y) LED grid.
  - each keypress is a "hit" at the pressed LED's (x,y) with an age in ms.
  - a hit paints a ripple: the wavefront reaches distance d at time d*spread, so
    nearer keys light first and farther keys are DELAYED (the ripple).
    Brightness stays CONSTANT (--value); the fade is a COLOUR blend from the
    ripple colour back into the base over `fade` ms, never a dimming.

Usage:
  ripple.py                 demo: auto-typing animation (Ctrl-C to quit)
  ripple.py --keys          interactive: keys drive it; Tab blanks/restores the
                            backlight (the screen-off preview). Ctrl-C quits.
  ripple.py --once          render one frame with a sample hit, then exit
  ripple.py --frames N      render N frames headless (no cursor tricks), exit
  ripple.py --from-board    start from what the KEYBOARD is running right now
  ripple.py --emit-set      print the `qmk-ripple set` lines for these values

In step with the rest of the package:
  - the flag names are the parameter names (`--radius` <-> `qmk-ripple set
    radius`), and the units match what `qmk-ripple show` prints;
  - the DEFAULTS are read from qmk/ripple_config.h, not copied here, so the
    simulator and the firmware cannot drift apart on what "default" means;
  - --from-board loads the live values over raw HID, and --emit-set prints the
    commands to push a tuned look back, closing the tune -> apply loop.

ripple_intensity() below is still a hand-mirrored port of the C in
rgb_matrix_user.inc -- two languages, so the MATH cannot be shared the way the
values now are. Keep the two in lockstep by hand; that pairing is the one
duplication left on purpose.
"""
import argparse, json, math, os, random, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LEDS = os.path.join(os.path.dirname(HERE), "leds", "cstm65.json")

sys.path.insert(0, os.path.join(os.path.dirname(HERE), "lib"))
try:
    import qmkripple as qr
except ImportError:
    sys.stderr.write("ripple.py: cannot import lib/qmkripple.py -- sim/ and "
                     "lib/ must stay siblings in the checkout.\n")
    sys.exit(1)


def hexrgb(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


class Params:
    def __init__(self, a):
        self.base = hexrgb(a.base)        # steady background colour
        self.hi = hexrgb(a.hi)            # ripple colour (at full blend)
        self.spread = a.spread            # ms of wavefront delay per grid unit
        self.radius = a.radius            # reach, grid units (2 keys ~= 26)
        self.keystep = a.keystep          # grid units per key
        self.peak = a.peak                # 1st-ring peak blend; ^ring outward
        self.fade = a.fade                # ms to blend back to base
        self.falloff = a.falloff          # time-fade curve (>1 lingers)
        self.value = a.value              # constant brightness 0..255
        self.mode = a.mode                # flat = base colour only, no ripple


def ripple_intensity(dist, age_ms, p):
    """Colour-BLEND amount [0,1] for a key `dist` units from a hit `age_ms` old.
    Two factors: a distance PEAK of `peak` per key-step (direct key 1.0,
    adjacent = peak, 2 keys out = peak^2 -> the outer ring is faint) times a
    time DECAY that blends back to base over `fade`. Brightness stays constant
    (held in led_color); distance sets the peak and delays arrival (the ripple).
    THIS IS THE QMK REFERENCE."""
    if dist > p.radius:
        return 0.0
    arrival = dist * p.spread             # the wavefront reaches this key later
    since = age_ms - arrival
    if since < 0.0:                       # wave hasn't arrived -> the delay
        return 0.0
    if since >= p.fade:                   # blended fully back to base
        return 0.0
    peak = p.peak ** (dist / p.keystep)   # peak blend, `peak` per key outward
    decay = (1.0 - since / p.fade) ** p.falloff
    return peak * decay


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def led_color(led, hits, now, p):
    x, y = led["x"], led["y"]
    inten = 0.0
    if p.mode == "flat":                  # matches RIPPLE_MODE_FLAT: the hit
        hits = ()                         # scan is skipped, every key is base
    for hx, hy, t0 in hits:
        d = math.hypot(x - hx, y - hy)
        inten = max(inten, ripple_intensity(d, (now - t0) * 1000.0, p))
        if inten >= 1.0:
            break
    mixed = lerp(p.base, p.hi, min(1.0, inten))   # blend base <-> ripple colour
    m = max(mixed)                                 # hold brightness constant:
    if m <= 0.0:                                   # scale so the brightest
        return (0, 0, 0)                           # channel == `value`
    return tuple(min(255, int(round(v * p.value / m))) for v in mixed)


# --- display grid: cluster LEDs into rows by y, place columns by x -----------
def build_grid(leds):
    ys = sorted({l["y"] for l in leds})
    rows = []
    for y in ys:
        if not rows or y - rows[-1][-1]["y"] > 6:
            rows.append([])
        rows[-1].append({"y": y})
    row_of = {}
    for ri, grp in enumerate(rows):
        yset = {g["y"] for g in grp}
        for l in leds:
            if l["y"] in yset:
                row_of[id(l)] = ri
    xmin = min(l["x"] for l in leds)
    xmax = max(l["x"] for l in leds)
    cols = 34
    cell = {}
    for l in leds:
        r = row_of[id(l)]
        c = round((l["x"] - xmin) / (xmax - xmin) * (cols - 1))
        cell[id(l)] = (r, c)
    return len(rows), cols, cell


def render(leds, cell, nrows, ncols, hits, now, p):
    canvas = [[None] * ncols for _ in range(nrows)]
    for l in leds:
        r, c = cell[id(l)]
        canvas[r][c] = led_color(l, hits, now, p)
    out = []
    for row in canvas:
        line = []
        for col in row:
            if col is None:
                line.append("  ")
            else:
                line.append(f"\x1b[38;2;{col[0]};{col[1]};{col[2]}m██")
        out.append("".join(line) + "\x1b[0m")
    return "\n".join(out)


def prune(hits, now, p):
    # a hit is dead once even the farthest reachable key has faded
    life = (p.radius * p.spread + p.fade) / 1000.0
    return [h for h in hits if now - h[2] < life]


# --- key -> LED position for interactive mode (approx QWERTY, snap to nearest)
QWERTY = {
    "`": (8, 7), "1": (22, 7), "2": (35, 7), "3": (49, 7), "4": (63, 7),
    "5": (77, 7), "6": (90, 7), "7": (104, 7), "8": (118, 7), "9": (132, 7),
    "0": (146, 7), "-": (160, 7), "=": (174, 7),
    "q": (26, 20), "w": (40, 20), "e": (54, 20), "r": (67, 20), "t": (81, 20),
    "y": (95, 20), "u": (108, 20), "i": (122, 20), "o": (136, 20),
    "p": (149, 20), "[": (163, 20), "]": (177, 20),
    "a": (28, 33), "s": (42, 33), "d": (56, 33), "f": (69, 33), "g": (83, 33),
    "h": (97, 33), "j": (111, 33), "k": (124, 33), "l": (138, 33),
    ";": (152, 33), "'": (166, 33),
    "z": (35, 46), "x": (49, 46), "c": (63, 46), "v": (76, 46), "b": (90, 46),
    "n": (104, 46), "m": (118, 46), ",": (131, 46), ".": (145, 46),
    "/": (159, 46), " ": (90, 56),
}


def snap(leds, xy):
    return min(leds, key=lambda l: math.hypot(l["x"] - xy[0], l["y"] - xy[1]))


def hit_xy(leds, ch):
    xy = QWERTY.get(ch.lower())
    l = snap(leds, xy) if xy else random.choice(leds)
    return (l["x"], l["y"])


def clock():
    return time.monotonic()


def frame(leds, cell, nr, nc, hits, now, p, home=True):
    body = render(leds, cell, nr, nc, hits, now, p)
    if home:
        sys.stdout.write("\x1b[H" + body + "\n")
    else:
        sys.stdout.write(body + "\n")
    sys.stdout.flush()


def run_demo(leds, cell, nr, nc, p, fps, frames=None):
    hits, i, t0 = [], 0, clock()
    nxt = t0
    sys.stdout.write("\x1b[2J\x1b[?25l")
    try:
        while frames is None or i < frames:
            now = clock()
            if now >= nxt:                # inject a "typed" key
                l = random.choice(leds)
                hits.append((l["x"], l["y"], now))
                nxt = now + random.uniform(0.08, 0.22)
            hits = prune(hits, now, p)
            frame(leds, cell, nr, nc, hits, now, p)
            i += 1
            time.sleep(max(0, 1.0 / fps - (clock() - now)))
    finally:
        sys.stdout.write("\x1b[?25h\n")


def run_keys(leds, cell, nr, nc, p, fps):
    import termios, tty, select
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    hits = []
    lit = p.value                    # remembered "on" brightness for the toggle
    sys.stdout.write("\x1b[2J\x1b[?25l")
    try:
        tty.setcbreak(fd)
        while True:
            now = clock()
            r, _, _ = select.select([fd], [], [], 0)
            if r:
                ch = sys.stdin.read(1)
                if ch in ("\x03", "\x04"):   # Ctrl-C / Ctrl-D
                    break
                if ch == "\t":               # Tab: blank/restore backlight,
                    p.value = 0.0 if p.value else lit   # the screen-off preview
                    continue
                x, y = hit_xy(leds, ch)
                hits.append((x, y, now))
            hits = prune(hits, now, p)
            frame(leds, cell, nr, nc, hits, now, p)
            time.sleep(1.0 / fps)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\x1b[?25h\n")


def main():
    # Defaults come from the FIRMWARE header, never a copy: see the module
    # docstring. A pre-pass reads --from-board so the live values become the
    # argparse defaults, which lets an explicit flag still override them.
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("--from-board", action="store_true")
    known, _rest = pre.parse_known_args()
    try:
        d = qr.firmware_defaults()
        src = "qmk/ripple_config.h"
        if known.from_board:
            d.update(qr.board_values())
            src = "the keyboard"
    except (qr.Error, qr.NotFound) as e:
        sys.stderr.write("ripple.py: %s\n" % e)
        return 1

    ap = argparse.ArgumentParser(
        description="ripple RGB effect simulator (defaults from %s)" % src)
    ap.add_argument("--leds", default=LEDS)
    ap.add_argument("--from-board", action="store_true",
                    help="take the starting values from the keyboard")
    ap.add_argument("--emit-set", action="store_true",
                    help="print the `qmk-ripple set` lines and exit")
    ap.add_argument("--base", default=d["base"], help="base colour hex")
    ap.add_argument("--hi", default=d["hi"], help="ripple colour hex")
    ap.add_argument("--spread", type=float, default=d["spread"],
                    help="ms delay/unit")
    ap.add_argument("--radius", type=float, default=d["radius"],
                    help="reach, units")
    ap.add_argument("--keystep", type=float, default=d["keystep"],
                    help="units per key")
    ap.add_argument("--peak", type=float, default=d["peak"],
                    help="1st-ring peak")
    ap.add_argument("--fade", type=float, default=d["fade"],
                    help="blend-back ms")
    ap.add_argument("--falloff", type=float, default=d["falloff"],
                    help="fade curve")
    ap.add_argument("--mode", choices=("ripple", "flat"),
                    default=d.get("mode", "ripple"),
                    help="flat = base colour only")
    ap.add_argument("--value", type=float, default=255.0, help="bright 0-255")
    ap.add_argument("--fps", type=float, default=60.0)
    ap.add_argument("--keys", action="store_true", help="interactive (raw tty)")
    ap.add_argument("--once", action="store_true", help="one frame, exit")
    ap.add_argument("--frames", type=int, help="render N frames headless, exit")
    a = ap.parse_args()

    if a.emit_set:
        # The tune -> apply loop: what you settled on here, as the commands
        # that put it on the board.
        for name in ("base", "hi", "spread", "radius", "peak", "fade",
                     "falloff", "keystep", "mode"):
            v = getattr(a, name)
            if isinstance(v, float) and v == int(v):
                v = int(v)
            print("qmk-ripple set %s %s" % (name, v))
        print("qmk-ripple save")
        return 0

    leds = json.load(open(a.leds))["leds"]
    p = Params(a)
    nr, nc, cell = build_grid(leds)

    if a.once:
        now = clock()
        c = snap(leds, (69, 33))          # a sample hit near 'f'
        frame(leds, cell, nr, nc, [(c["x"], c["y"], now - 0.06)], now, p,
              home=False)
        return 0
    if a.frames is not None:
        run_demo(leds, cell, nr, nc, p, a.fps, frames=a.frames)
        return 0
    if a.keys:
        run_keys(leds, cell, nr, nc, p, a.fps)
        return 0
    run_demo(leds, cell, nr, nc, p, a.fps)
    return 0


if __name__ == "__main__":
    sys.exit(main())
