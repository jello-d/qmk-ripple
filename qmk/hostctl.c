// hostctl.c -- raw-HID host control of the RGB backlight, for the screen-off
// integration (panel-power). RAW_ENABLE (rules.mk) exposes the 0xFF60 raw-HID
// interface; this handler turns the matrix off/on on a one-byte command:
//   0x01 -> off        (rgb_matrix_disable_noeeprom: LEDs dark, effect paused)
//   0x02 -> on         (rgb_matrix_enable_noeeprom:  effect resumes)
//   0x03 -> bootloader (jump to the flasher, so a reflash needs no reset pin)
// noeeprom = transient (a power cycle returns to the saved on-state), which is
// exactly right for "off while the screen sleeps". The command is echoed back
// as an ack so the host can confirm the write landed. A transient off must
// never outlive the host that asked for it; see the USB hook at the bottom for
// the reboot case, where a power cycle alone is not enough.
#include QMK_KEYBOARD_H
#include "raw_hid.h"
#include "usb_device_state.h"

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
            // reset_keyboard(), NOT a bare bootloader_jump(): the jump alone
            // skips shutdown_quantum(), so shutdown_kb/shutdown_user never
            // run and the red indicator below never paints (observed: the
            // board entered the bootloader with the keys still blue).
            // reset_keyboard() runs the shutdown hooks, waits 250ms so the
            // IS31FL3733 latches the colour, and only then jumps.
            reset_keyboard(); // does not return
            return;
        default:
            break;
    }
    raw_hid_send(data, length); // ack: echo the command back
}

// The backlight is ON by default, and a host-commanded off is transient state
// that any power event or reboot wipes. A real power cycle already does that:
// the off lives in MCU RAM (noeeprom) and RGB_MATRIX_DEFAULT_ON restores the
// lit state from EEPROM. A host REBOOT does NOT: the USB port holds 5V, so the
// MCU never resets, the RAM flag survives, and the board comes back dark with
// the session that owed it an "on" gone for good.
//
// What the keyboard does see across a reboot is a fresh USB enumeration, so we
// treat that as the wipe. Entering CONFIGURED from INIT means the bus was
// reset and a NEW host enumerated us (reboot, replug, KVM switch), and the
// matrix goes back on.
//
// Two transitions are deliberately NOT a wipe:
//   SUSPEND -> CONFIGURED  the same host waking from sleep, its session
//                          intact. Relighting would defeat a blank that is
//                          still in force; that host restores on unlock.
//   CONFIGURED -> CONFIGURED  not an enumeration at all. usb_device_state's
//                          set_leds/set_protocol/set_idle_rate all notify with
//                          the state unchanged, so this fires on every caps-
//                          lock report; relighting here would undo the blank
//                          within milliseconds.
static usb_configure_state_t hostctl_last_state = USB_DEVICE_STATE_NO_INIT;

void notify_usb_device_state_change_user(struct usb_device_state state) {
    usb_configure_state_t was = hostctl_last_state;
    hostctl_last_state        = state.configure_state;

    if (state.configure_state != USB_DEVICE_STATE_CONFIGURED) {
        return;
    }
    if (was != USB_DEVICE_STATE_INIT && was != USB_DEVICE_STATE_NO_INIT) {
        return; // same host: a wake, or a re-notify while already configured
    }
    rgb_matrix_enable_noeeprom();
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
// firmware won't show it. Reaching here at all requires the caller to go
// through shutdown_quantum() (reset_keyboard does; a bare bootloader_jump()
// does NOT) -- see the 0x03 case above, which got that wrong once.
bool shutdown_user(bool jump_to_bootloader) {
    if (jump_to_bootloader) {
        rgb_matrix_set_color_all(RGB_BOOT_R, RGB_BOOT_G, RGB_BOOT_B);
        rgb_matrix_update_pwm_buffers();
    }
    return true;
}
