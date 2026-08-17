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
#        define RIPPLE_RADIUS 34    // reach in grid units (~15/key)
#    endif
#    ifndef RIPPLE_FADE
#        define RIPPLE_FADE 325     // ms a key stays lit after the wave arrives
#    endif
#    ifndef RIPPLE_FALLOFF
#        define RIPPLE_FALLOFF 1.4f // distance dimming curve (>=1 = steeper)
#    endif

// highlight intensity [0,255] for a key `dist` units from a hit `age` ms old.
// == ripple_intensity() in sim/ripple.py.
static uint8_t ripple_intensity(uint16_t dist, uint16_t age) {
    if (dist > RIPPLE_RADIUS) return 0;
    uint16_t arrival = dist * RIPPLE_SPREAD;
    if (age < arrival) return 0;              // wavefront not here yet: the delay
    uint16_t since = age - arrival;
    if (since >= RIPPLE_FADE) return 0;
    float tfade = 1.0f - (float)since / (float)RIPPLE_FADE;   // fade after arrival
    float dfall = 1.0f - (float)dist / (float)RIPPLE_RADIUS;  // dimmer farther out
    float inten = tfade * powf(dfall, RIPPLE_FALLOFF);
    if (inten <= 0.0f) return 0;
    if (inten >= 1.0f) return 255;
    return (uint8_t)(inten * 255.0f);
}

static bool RIPPLE(effect_params_t* params) {
    RGB_MATRIX_USE_LIMITS(led_min, led_max);

    for (uint8_t i = led_min; i < led_max; i++) {
        RGB_MATRIX_TEST_LED_FLAGS();
        uint8_t best = 0;                     // strongest ripple over all hits
        for (uint8_t j = 0; j < g_last_hit_tracker.count; j++) {
            int16_t dx = (int16_t)g_led_config.point[i].x - g_last_hit_tracker.x[j];
            int16_t dy = (int16_t)g_led_config.point[i].y - g_last_hit_tracker.y[j];
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            if (dx > RIPPLE_RADIUS || dy > RIPPLE_RADIUS) continue;  // bbox skip
            uint16_t dist  = sqrt16((uint16_t)(dx * dx + dy * dy));
            uint8_t  inten = ripple_intensity(dist, g_last_hit_tracker.tick[j]);
            if (inten > best) best = inten;
        }
        // blend base -> highlight by best/255 (signed deltas: hi may be < base)
        uint8_t r = (uint8_t)(RIPPLE_BASE_R + ((RIPPLE_HI_R - RIPPLE_BASE_R) * best) / 255);
        uint8_t g = (uint8_t)(RIPPLE_BASE_G + ((RIPPLE_HI_G - RIPPLE_BASE_G) * best) / 255);
        uint8_t b = (uint8_t)(RIPPLE_BASE_B + ((RIPPLE_HI_B - RIPPLE_BASE_B) * best) / 255);
        rgb_matrix_set_color(i, r, g, b);
    }
    return rgb_matrix_check_finished_leds(led_max);
}

#endif // RGB_MATRIX_CUSTOM_EFFECT_IMPLS
