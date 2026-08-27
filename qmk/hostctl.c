// hostctl.c -- raw-HID host control of the RGB backlight, for the screen-off
// integration (panel-power). RAW_ENABLE (rules.mk) exposes the 0xFF60 raw-HID
// interface; this handler turns the matrix off/on on a one-byte command:
//   0x01 -> off        (rgb_matrix_disable_noeeprom: LEDs dark, effect paused)
//   0x02 -> on         (rgb_matrix_enable_noeeprom:  effect resumes)
//   0x03 -> bootloader (jump to the flasher, so a reflash needs no reset pin)
// noeeprom = transient (a power cycle returns to the saved on-state), which is
// exactly right for "off while the screen sleeps". The command is echoed back
// as an ack so the host can confirm the write landed.
#include QMK_KEYBOARD_H
#include "raw_hid.h"

enum hostctl_cmd {
    HOSTCTL_RGB_OFF    = 0x01,
    HOSTCTL_RGB_ON     = 0x02,
    HOSTCTL_BOOTLOADER = 0x03,
};

void raw_hid_receive(uint8_t *data, uint8_t length) {
    switch (data[0]) {
        case HOSTCTL_RGB_OFF:
            rgb_matrix_disable_noeeprom();
            break;
        case HOSTCTL_RGB_ON:
            rgb_matrix_enable_noeeprom();
            break;
        case HOSTCTL_BOOTLOADER:
            raw_hid_send(data, length); // ack before we vanish
            bootloader_jump();          // does not return
            return;
        default:
            break;
    }
    raw_hid_send(data, length); // ack: echo the command back
}

// Bootloader indicator colour (default: solid red, distinct from the blue /
// run-time palette). Overridable from config.h.
#ifndef RGB_BOOT_R
#    define RGB_BOOT_R 0xFF
#    define RGB_BOOT_G 0x00
#    define RGB_BOOT_B 0x00
#endif

// Called just before QMK jumps to the bootloader (QK_BOOT, the 0x03 command, or
// a double-tap reset that routes through firmware). Paint the whole matrix the
// indicator colour and FLUSH it: the IS31FL3733 latches its PWM registers and
// holds them with no firmware running, so the colour persists THROUGH the
// bootloader -- a clear "I am in flashing mode". A plain reset that skips
// firmware won't show it, but the deliberate paths all pass here.
bool shutdown_user(bool jump_to_bootloader) {
    if (jump_to_bootloader) {
        rgb_matrix_set_color_all(RGB_BOOT_R, RGB_BOOT_G, RGB_BOOT_B);
        rgb_matrix_update_pwm_buffers();
    }
    return true;
}
