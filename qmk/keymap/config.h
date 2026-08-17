#pragma once

// The ripple effect reads g_last_hit_tracker (keypress positions + ages); this
// enables that tracker even if the built-in reactive effects are trimmed.
#define RGB_MATRIX_KEYREACTIVE_ENABLED

// Boot straight into the custom effect.
#define RGB_MATRIX_DEFAULT_MODE RGB_MATRIX_CUSTOM_RIPPLE

// Re-tuned simulator values would be pasted here as RIPPLE_* overrides, e.g.:
//   #define RIPPLE_HI_R 0x7a
//   #define RIPPLE_HI_G 0x00
//   #define RIPPLE_HI_B 0xb8
