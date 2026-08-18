// hostctl.c -- raw-HID host control of the RGB backlight, for the screen-off
// integration (panel-power). RAW_ENABLE (rules.mk) exposes the 0xFF60 raw-HID
// interface; this handler turns the matrix off/on on a one-byte command:
//   0x01 -> off   (rgb_matrix_disable_noeeprom: LEDs dark, effect paused)
//   0x02 -> on    (rgb_matrix_enable_noeeprom:  effect resumes)
// noeeprom = transient (a power cycle returns to the saved on-state), which is
// exactly right for "off while the screen sleeps". The command is echoed back
// as an ack so the host can confirm the write landed.
#include QMK_KEYBOARD_H
#include "raw_hid.h"

enum hostctl_cmd {
    HOSTCTL_RGB_OFF = 0x01,
    HOSTCTL_RGB_ON  = 0x02,
};

void raw_hid_receive(uint8_t *data, uint8_t length) {
    switch (data[0]) {
        case HOSTCTL_RGB_OFF:
            rgb_matrix_disable_noeeprom();
            break;
        case HOSTCTL_RGB_ON:
            rgb_matrix_enable_noeeprom();
            break;
        default:
            break;
    }
    raw_hid_send(data, length); // ack: echo the command back
}
