#!/bin/sh
# test/firmware.t - the C-side invariants that are cheap to check on the host.
#
# A full QMK build needs a cross toolchain and a vendored qmk tree, so it is
# not run here (qmk/build.sh is that path). These are the facts that do NOT
# need a firmware build and that fail EXPENSIVELY if wrong:
#
#   - the config struct must fit the EEPROM block it is saved into. Too big and
#     eeconfig_update_user_datablock silently truncates, so a save writes
#     garbage that the next boot reads back as settings.
#   - a saved layout must be versioned, or an old block is read as a new struct
#     and the effect renders from nonsense.
#   - the bootloader jump must go through reset_keyboard(), not a bare
#     bootloader_jump(): the bare call skips shutdown_quantum() so the red
#     indicator never paints. That shipped once.
#   - the relight hook must not fire on every notify. set_leds/set_protocol
#     notify with the state UNCHANGED, so a naive "relight when configured"
#     undoes each blank within milliseconds.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init firmware

SRC=$HERE/qmk/hostctl.c
HDR=$HERE/qmk/ripple_config.h
CFG=$HERE/qmk/keymap/config.h
INC=$HERE/qmk/rgb_matrix_user.inc
bad=""

note() { bad="$bad
  $1"; }

# --- the jump runs the shutdown hooks --------------------------------------
grep -q "reset_keyboard();" "$SRC" \
  || note "the 0x03 case does not call reset_keyboard(); a bare
  bootloader_jump() skips shutdown_quantum and the red indicator never paints"
if grep -E "^\s+bootloader_jump\(\);" "$SRC" >/dev/null 2>&1; then
  note "a bare bootloader_jump() is back in hostctl.c"
fi

# --- the relight is gated on a real enumeration ----------------------------
grep -q "USB_DEVICE_STATE_CONFIGURED" "$SRC" \
  || note "the USB relight hook is gone"
grep -q "USB_DEVICE_STATE_INIT" "$SRC" \
  || note "the relight no longer distinguishes INIT (a fresh enumeration)
  from any other transition, so it will fire on every LED report"
grep -q "rgb_matrix_enable_noeeprom" "$SRC" \
  || note "the relight no longer enables the matrix"
grep -q "rgb_matrix_reload_from_eeprom" "$SRC" \
  && note "the relight uses reload_from_eeprom, which also reverts mode, hue
  and brightness: wider than the bug it fixes"

# --- persistence is versioned ----------------------------------------------
grep -q "RIPPLE_CONFIG_VERSION" "$HDR" \
  || note "the config struct is unversioned"
grep -q "stored.version != RIPPLE_CONFIG_VERSION" "$SRC" \
  || note "the load path does not check the stored layout version, so an old
  EEPROM block would be read as the current struct"

# --- FLAT mode really skips the work ---------------------------------------
grep -q "RIPPLE_MODE_FLAT" "$INC" \
  || note "the effect does not honour FLAT mode, so `mode flat` renders the
  ripple anyway"

# --- the struct fits its EEPROM block --------------------------------------
_size=$(grep -E "^#define EECONFIG_USER_DATA_SIZE" "$CFG" | awk '{print $3}')
[ -n "$_size" ] || note "EECONFIG_USER_DATA_SIZE is not defined in the keymap
  config.h, so the user datablock API is compiled out entirely"

if command -v gcc >/dev/null 2>&1 && [ -n "$_size" ]; then
  cat > "$T/s.c" <<EOF
#include <stdio.h>
#include <stddef.h>
#include "ripple_config.h"
int main(void) { printf("%zu\n", sizeof(ripple_config_t)); return 0; }
EOF
  if gcc -I "$HERE/qmk" -o "$T/s" "$T/s.c" 2>/dev/null; then
    _actual=$("$T/s")
    [ "$_actual" -le "$_size" ] || note "sizeof(ripple_config_t) is $_actual but
  EECONFIG_USER_DATA_SIZE is $_size: a save would be truncated"
  else
    note "ripple_config.h does not compile standalone"
  fi
else
  printf 'SKIP firmware: no gcc, so the struct/EEPROM size check did not run\n'
  printf '     (everything else in this test did)\n'
fi

if [ -n "$bad" ]; then
  printf '%s\n' "$bad" | sed '/^$/d' >&2
  fail "firmware invariants above"
fi

pass "jump path, relight gating, versioned persistence, struct fits EEPROM"
