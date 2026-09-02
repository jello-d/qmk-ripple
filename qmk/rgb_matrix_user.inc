// rgb_matrix_user.inc -- custom QMK RGB-matrix effect: a solid base colour with
// a reactive water-ripple highlight on keypress. Drop this file into a keymap
// dir (QMK auto-includes it when rules.mk has RGB_MATRIX_CUSTOM_USER = yes) and
// select RGB_MATRIX_CUSTOM_RIPPLE (see qmk/README.md for the wiring).
//
// The intensity math is a verbatim port of ripple_intensity() in
// sim/ripple.py -- tune in the simulator, then mirror the constants here.
// Coordinates are QMK's shared LED grid (0..224 x 0..64), the same space the
// simulator uses, so distances and the look carry over 1:1.

RGB_MATRIX_EFFECT(RIPPLE)

#ifdef RGB_MATRIX_CUSTOM_EFFECT_IMPLS

#    include <math.h>
#    include "ripple_config.h"

// The tunables used to be #defines consumed right here. They now live in
// ripple_config (see ripple_config.h), so the host can retune the effect over
// raw HID with no reflash; the #define values survive as its boot defaults, so
// a keymap's config.h still sets the look exactly as it used to.

// colour-BLEND amount [0,255] for a key `dist` units from a hit `age` ms old:
// a distance PEAK per key-step (direct 1.0, adjacent = peak, 2 keys = peak^2)
// times a time DECAY back to base over `fade`. Brightness is held constant
// below. == ripple_intensity() in sim/ripple.py.
static uint8_t ripple_intensity(uint16_t dist, uint16_t age) {
    if (dist > ripple_config.radius) return 0;
    uint16_t arrival = dist * ripple_config.spread;
    if (age < arrival) return 0;              // not here yet: this is the delay
    uint16_t since = age - arrival;
    if (since >= ripple_config.fade) return 0;
    float t       = 1.0f - (float)since / (float)ripple_config.fade;
    float peak    = (float)ripple_config.peak_x100 / 100.0f;
    float keystep = (float)ripple_config.keystep_x100 / 100.0f;
    float falloff = (float)ripple_config.falloff_x100 / 100.0f;
    float amount  = powf(peak, (float)dist / keystep);
    return (uint8_t)(amount * powf(t, falloff) * 255.0f);
}

static bool RIPPLE(effect_params_t* params) {
    RGB_MATRIX_USE_LIMITS(led_min, led_max);
    int v = rgb_matrix_config.hsv.v;          // global brightness

    for (uint8_t i = led_min; i < led_max; i++) {
        RGB_MATRIX_TEST_LED_FLAGS();
        led_point_t pt = g_led_config.point[i];
        int best = 0;                         // strongest ripple over all hits
        // FLAT mode skips the hit scan entirely: best stays 0, so every key
        // renders the base colour and keypresses do nothing. That is the
        // "ripple off, plain colour" toggle, and it is also the cheap path.
        if (ripple_config.mode != RIPPLE_MODE_FLAT) {
            int16_t reach = (int16_t)ripple_config.radius;
            for (uint8_t j = 0; j < g_last_hit_tracker.count; j++) {
                int16_t dx = pt.x - g_last_hit_tracker.x[j];
                int16_t dy = pt.y - g_last_hit_tracker.y[j];
                if (dx < 0) dx = -dx;
                if (dy < 0) dy = -dy;
                if (dx > reach || dy > reach) continue;             // bbox
                uint16_t dist = sqrt16((uint16_t)(dx * dx + dy * dy));
                int inten =
                    ripple_intensity(dist, g_last_hit_tracker.tick[j]);
                if (inten > best) best = inten;
            }
        }
        // colour blend base -> ripple by best/255 (signed: hi may be < base)
        int br = ripple_config.base_r, bg = ripple_config.base_g;
        int bb = ripple_config.base_b;
        int mr = br + ((ripple_config.hi_r - br) * best) / 255;
        int mg = bg + ((ripple_config.hi_g - bg) * best) / 255;
        int mb = bb + ((ripple_config.hi_b - bb) * best) / 255;
        // hold brightness constant: scale so the brightest channel == v (the
        // global brightness), so keys never dim and VialRGB val drives on/off.
        int m = mr > mg ? mr : mg;
        if (mb > m) m = mb;
        uint8_t r = 0, g = 0, b = 0;
        if (m > 0) {
            r = (uint8_t)(mr * v / m);
            g = (uint8_t)(mg * v / m);
            b = (uint8_t)(mb * v / m);
        }
        rgb_matrix_set_color(i, r, g, b);
    }
    return rgb_matrix_check_finished_leds(led_max);
}

#endif // RGB_MATRIX_CUSTOM_EFFECT_IMPLS
