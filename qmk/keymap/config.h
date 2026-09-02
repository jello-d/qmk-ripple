#pragma once

// The ripple effect reads g_last_hit_tracker (keypress positions + ages);
// RGB_MATRIX_KEYPRESSES enables that tracking (built-in reactive effects
// rely on it too, but define it so the effect works even if those are trimmed).
#define RGB_MATRIX_KEYPRESSES

// Boot straight into the custom effect.
#define RGB_MATRIX_DEFAULT_MODE RGB_MATRIX_CUSTOM_RIPPLE

// Re-tuned simulator values would be pasted here as RIPPLE_* overrides, e.g.:
//   #define RIPPLE_HI_R 0x7a
//   #define RIPPLE_HI_G 0x00
//   #define RIPPLE_HI_B 0xb8

// Runtime-tunable effect params live in the user EEPROM datablock (see
// qmk/ripple_config.h). Sized with headroom: the struct carries reserved
// fields so a new parameter does not change the block size, which would
// invalidate everyone's saved config.
#define EECONFIG_USER_DATA_SIZE 32
