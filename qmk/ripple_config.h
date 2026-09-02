// Copyright 2026 jello-d
// SPDX-License-Identifier: Apache-2.0
//
// ripple_config.h -- the runtime-tunable state of the ripple effect, shared
// between hostctl.c (which owns the instance and the host protocol) and
// rgb_matrix_user.inc (which renders from it). They are separate translation
// units -- the .inc is included into QMK's rgb_matrix.c -- so the struct has
// to live in a header both can see.
//
// Everything here used to be a compile-time #define. The defaults still are,
// so a keymap's config.h can set the boot values exactly as before; what
// changed is that the effect now reads a struct, so the host can retune it
// over raw HID with no reflash.
//
// Floats are stored as fixed point (x100) because the wire protocol carries
// integers and EEPROM should not hold a float layout. The effect converts on
// use; the cost is a divide per frame, not per LED.
#pragma once

#include <stdint.h>

// --- compile-time defaults (unchanged names, so old overrides still work) ---
#ifndef RIPPLE_BASE_R
#    define RIPPLE_BASE_R 0x00
#    define RIPPLE_BASE_G 0x00
#    define RIPPLE_BASE_B 0xFF  // base: blue (0000ff)
#endif
#ifndef RIPPLE_HI_R
#    define RIPPLE_HI_R 0x94
#    define RIPPLE_HI_G 0x00
#    define RIPPLE_HI_B 0xD3    // highlight: deep purple (9400d3)
#endif
#ifndef RIPPLE_SPREAD
#    define RIPPLE_SPREAD 5     // ms of wavefront delay per grid unit
#endif
#ifndef RIPPLE_RADIUS
#    define RIPPLE_RADIUS 26    // reach in grid units (2 keys ~= 26)
#endif
#ifndef RIPPLE_KEYSTEP
#    define RIPPLE_KEYSTEP 13   // grid units per key
#endif
#ifndef RIPPLE_PEAK
#    define RIPPLE_PEAK 33      // 1st-ring peak blend, PERCENT
#endif
#ifndef RIPPLE_FADE
#    define RIPPLE_FADE 216     // ms to blend back to base after arrival
#endif
#ifndef RIPPLE_FALLOFF
#    define RIPPLE_FALLOFF 100  // time-fade curve, PERCENT (>100 lingers)
#endif

// Bump when the struct layout changes: a mismatch makes the firmware ignore
// the stored block and fall back to the defaults above, so a layout change can
// never be read as garbage settings.
#define RIPPLE_CONFIG_VERSION 1

enum ripple_mode {
    RIPPLE_MODE_FLAT   = 0,  // base colour only; keypresses do nothing
    RIPPLE_MODE_RIPPLE = 1,  // the reactive effect
};

typedef struct {
    uint8_t  version;
    uint8_t  mode;
    uint8_t  base_r, base_g, base_b;
    uint8_t  hi_r, hi_g, hi_b;
    uint16_t spread;        // ms per grid unit
    uint16_t radius;        // grid units
    uint16_t fade;          // ms
    uint16_t peak_x100;     // percent
    uint16_t falloff_x100;  // percent
    uint16_t keystep_x100;  // grid units x100
    uint16_t reserved[4];   // room for new params without resizing EEPROM
} ripple_config_t;

extern ripple_config_t ripple_config;

// Wire parameter ids (host <-> firmware). Append only: an id is forever.
enum ripple_param {
    RIPPLE_P_BASE    = 0x01,  // packed 0x00RRGGBB
    RIPPLE_P_HI      = 0x02,  // packed 0x00RRGGBB
    RIPPLE_P_SPREAD  = 0x03,
    RIPPLE_P_RADIUS  = 0x04,
    RIPPLE_P_PEAK    = 0x05,  // percent
    RIPPLE_P_FADE    = 0x06,
    RIPPLE_P_FALLOFF = 0x07,  // percent
    RIPPLE_P_KEYSTEP = 0x08,  // x100
    RIPPLE_P_MODE    = 0x09,
};
