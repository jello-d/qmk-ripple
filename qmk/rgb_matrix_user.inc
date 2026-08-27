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

// --- tunables (defaults match the simulator's v1) ---------------------------
#    ifndef RIPPLE_BASE_R
#        define RIPPLE_BASE_R 0x00
#        define RIPPLE_BASE_G 0x00
#        define RIPPLE_BASE_B 0xFF  // base: blue (0000ff)
#    endif
#    ifndef RIPPLE_HI_R
#        define RIPPLE_HI_R 0x94
#        define RIPPLE_HI_G 0x00
#        define RIPPLE_HI_B 0xD3    // highlight: deep purple (9400d3)
#    endif
#    ifndef RIPPLE_SPREAD
#        define RIPPLE_SPREAD 5     // ms of wavefront delay per grid unit
#    endif
#    ifndef RIPPLE_RADIUS
#        define RIPPLE_RADIUS 26    // reach in grid units (2 keys ~= 26)
#    endif
#    ifndef RIPPLE_KEYSTEP
#        define RIPPLE_KEYSTEP 13.0f // grid units per key
#    endif
#    ifndef RIPPLE_PEAK
#        define RIPPLE_PEAK 0.33f    // 1st-ring peak blend; ^ring outward
#    endif
#    ifndef RIPPLE_FADE
#        define RIPPLE_FADE 216     // ms to blend back to base after arrival
#    endif
#    ifndef RIPPLE_FALLOFF
#        define RIPPLE_FALLOFF 1.0f // time-fade curve (>1 lingers then drops)
#    endif

// colour-BLEND amount [0,255] for a key `dist` units from a hit `age` ms old:
// a distance PEAK of RIPPLE_PEAK per key-step (direct 1.0, adjacent = PEAK,
// 2 keys = PEAK^2) times a time DECAY back to base over RIPPLE_FADE. Brightness
// is held constant below. == ripple_intensity() in sim/ripple.py.
static uint8_t ripple_intensity(uint16_t dist, uint16_t age) {
    if (dist > RIPPLE_RADIUS) return 0;
    uint16_t arrival = dist * RIPPLE_SPREAD;
    if (age < arrival) return 0;              // not here yet: this is the delay
    uint16_t since = age - arrival;
    if (since >= RIPPLE_FADE) return 0;
    float t    = 1.0f - (float)since / (float)RIPPLE_FADE;
    float peak = powf(RIPPLE_PEAK, (float)dist / RIPPLE_KEYSTEP);
    return (uint8_t)(peak * powf(t, RIPPLE_FALLOFF) * 255.0f);
}

static bool RIPPLE(effect_params_t* params) {
    RGB_MATRIX_USE_LIMITS(led_min, led_max);
    int v = rgb_matrix_config.hsv.v;          // global brightness

    for (uint8_t i = led_min; i < led_max; i++) {
        RGB_MATRIX_TEST_LED_FLAGS();
        led_point_t pt = g_led_config.point[i];
        int best = 0;                         // strongest ripple over all hits
        for (uint8_t j = 0; j < g_last_hit_tracker.count; j++) {
            int16_t dx = pt.x - g_last_hit_tracker.x[j];
            int16_t dy = pt.y - g_last_hit_tracker.y[j];
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            if (dx > RIPPLE_RADIUS || dy > RIPPLE_RADIUS) continue; // bbox
            uint16_t dist  = sqrt16((uint16_t)(dx * dx + dy * dy));
            int      inten = ripple_intensity(dist, g_last_hit_tracker.tick[j]);
            if (inten > best) best = inten;
        }
        // colour blend base -> ripple by best/255 (signed: hi may be < base)
        int mr = RIPPLE_BASE_R + ((RIPPLE_HI_R - RIPPLE_BASE_R) * best) / 255;
        int mg = RIPPLE_BASE_G + ((RIPPLE_HI_G - RIPPLE_BASE_G) * best) / 255;
        int mb = RIPPLE_BASE_B + ((RIPPLE_HI_B - RIPPLE_BASE_B) * best) / 255;
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
