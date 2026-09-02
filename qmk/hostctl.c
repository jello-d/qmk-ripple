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
#include "eeconfig.h"
#include "ripple_config.h"
#include <string.h>

// LEGACY flat commands. These bytes sit in VIA's id space and cannot be moved
// without breaking a host that is already deployed, so they stay exactly as
// they are and everything NEW goes behind the RIPPLE_PREFIX namespace below.
enum hostctl_cmd {
    HOSTCTL_RGB_OFF    = 0x01,
    HOSTCTL_RGB_ON     = 0x02,
    HOSTCTL_BOOTLOADER = 0x03,
};

// Namespaced protocol: every v2 message is [0x52]['R'-ish subcmd][payload].
// 0x52 is undefined in VIA's command space, so one of these aimed at a VIA
// board falls into its id_unhandled branch and does NOTHING -- unlike the flat
// bytes above, where our 0x03 is VIA's id_set_keyboard_value, a WRITE. It also
// gives us a trustworthy IDENTIFY: only this firmware answers with the magic,
// so a host can positively confirm what it is talking to rather than guessing
// from the presence of a 0xFF60 interface (which VIA has too).
#define RIPPLE_PREFIX 0x52

enum ripple_subcmd {
    RIPPLE_SUB_IDENTIFY = 0x00,
    RIPPLE_SUB_GET      = 0x10,
    RIPPLE_SUB_SET      = 0x11,
    RIPPLE_SUB_SAVE     = 0x12,
    RIPPLE_SUB_RESET    = 0x13,
};

enum ripple_status {
    RIPPLE_OK       = 0x00,
    RIPPLE_EBADID   = 0x01,  // no such parameter
    RIPPLE_ERANGE   = 0x02,  // value outside the parameter's range
    RIPPLE_EBADCMD  = 0x03,  // no such subcommand
};

#define RIPPLE_PROTO_VERSION 1
#define RIPPLE_MAGIC0 'R'
#define RIPPLE_MAGIC1 'P'
#define RIPPLE_MAGIC2 'L'

ripple_config_t ripple_config;

// --- the parameter table ----------------------------------------------------
// Ranges live HERE, not in the host, and GET reports them alongside the value.
// One source of truth: a host cannot drift out of step with what the firmware
// will actually accept, and `show` can print real limits without a second copy.
typedef struct {
    uint8_t  id;
    uint32_t min;
    uint32_t max;
} ripple_param_meta_t;

static const ripple_param_meta_t ripple_params[] = {
    {RIPPLE_P_BASE,    0, 0xFFFFFF},
    {RIPPLE_P_HI,      0, 0xFFFFFF},
    {RIPPLE_P_SPREAD,  0, 1000},
    {RIPPLE_P_RADIUS,  0, 255},
    {RIPPLE_P_PEAK,    1, 100},
    {RIPPLE_P_FADE,    1, 5000},
    {RIPPLE_P_FALLOFF, 1, 1000},
    {RIPPLE_P_KEYSTEP, 100, 10000},
    {RIPPLE_P_MODE,    RIPPLE_MODE_FLAT, RIPPLE_MODE_RIPPLE},
};
#define RIPPLE_NPARAMS (sizeof(ripple_params) / sizeof(ripple_params[0]))

static const ripple_param_meta_t *ripple_meta(uint8_t id) {
    for (uint8_t i = 0; i < RIPPLE_NPARAMS; i++) {
        if (ripple_params[i].id == id) return &ripple_params[i];
    }
    return NULL;
}

void ripple_config_defaults(void) {
    ripple_config.version      = RIPPLE_CONFIG_VERSION;
    ripple_config.mode         = RIPPLE_MODE_RIPPLE;
    ripple_config.base_r       = RIPPLE_BASE_R;
    ripple_config.base_g       = RIPPLE_BASE_G;
    ripple_config.base_b       = RIPPLE_BASE_B;
    ripple_config.hi_r         = RIPPLE_HI_R;
    ripple_config.hi_g         = RIPPLE_HI_G;
    ripple_config.hi_b         = RIPPLE_HI_B;
    ripple_config.spread       = RIPPLE_SPREAD;
    ripple_config.radius       = RIPPLE_RADIUS;
    ripple_config.fade         = RIPPLE_FADE;
    ripple_config.peak_x100    = RIPPLE_PEAK;
    ripple_config.falloff_x100 = RIPPLE_FALLOFF;
    ripple_config.keystep_x100 = RIPPLE_KEYSTEP * 100;
    memset(ripple_config.reserved, 0, sizeof(ripple_config.reserved));
}

static uint32_t ripple_get(uint8_t id) {
    switch (id) {
        case RIPPLE_P_BASE:
            return ((uint32_t)ripple_config.base_r << 16) |
                   ((uint32_t)ripple_config.base_g << 8) | ripple_config.base_b;
        case RIPPLE_P_HI:
            return ((uint32_t)ripple_config.hi_r << 16) |
                   ((uint32_t)ripple_config.hi_g << 8) | ripple_config.hi_b;
        case RIPPLE_P_SPREAD:  return ripple_config.spread;
        case RIPPLE_P_RADIUS:  return ripple_config.radius;
        case RIPPLE_P_PEAK:    return ripple_config.peak_x100;
        case RIPPLE_P_FADE:    return ripple_config.fade;
        case RIPPLE_P_FALLOFF: return ripple_config.falloff_x100;
        case RIPPLE_P_KEYSTEP: return ripple_config.keystep_x100;
        case RIPPLE_P_MODE:    return ripple_config.mode;
    }
    return 0;
}

static void ripple_set(uint8_t id, uint32_t v) {
    switch (id) {
        case RIPPLE_P_BASE:
            ripple_config.base_r = (v >> 16) & 0xFF;
            ripple_config.base_g = (v >> 8) & 0xFF;
            ripple_config.base_b = v & 0xFF;
            break;
        case RIPPLE_P_HI:
            ripple_config.hi_r = (v >> 16) & 0xFF;
            ripple_config.hi_g = (v >> 8) & 0xFF;
            ripple_config.hi_b = v & 0xFF;
            break;
        case RIPPLE_P_SPREAD:  ripple_config.spread       = v; break;
        case RIPPLE_P_RADIUS:  ripple_config.radius       = v; break;
        case RIPPLE_P_PEAK:    ripple_config.peak_x100    = v; break;
        case RIPPLE_P_FADE:    ripple_config.fade         = v; break;
        case RIPPLE_P_FALLOFF: ripple_config.falloff_x100 = v; break;
        case RIPPLE_P_KEYSTEP: ripple_config.keystep_x100 = v; break;
        case RIPPLE_P_MODE:    ripple_config.mode         = v; break;
    }
}

// --- persistence -------------------------------------------------------------
// A set is TRANSIENT (RAM only); SAVE is what commits. So a live sweep of a
// value costs no flash wear, an experiment you dislike dies at the next power
// cycle, and the saved config stays a known-good fallback. Same transient-vs-
// persisted split the backlight off/on already uses.
static void ripple_config_load(void) {
    ripple_config_t stored;
    eeconfig_read_user_datablock(&stored, 0, sizeof(stored));
    if (stored.version != RIPPLE_CONFIG_VERSION) {
        ripple_config_defaults();  // never read an old layout as settings
        return;
    }
    ripple_config = stored;
}

static void ripple_config_save(void) {
    eeconfig_update_user_datablock(&ripple_config, 0, sizeof(ripple_config));
}

void keyboard_post_init_user(void) {
    ripple_config_load();
}

// --- the namespaced command handler -----------------------------------------
static void ripple_reply(uint8_t *data, uint8_t sub, uint8_t status,
                         uint8_t id) {
    data[0] = RIPPLE_PREFIX;
    data[1] = sub;
    data[2] = status;
    data[3] = id;
}

static void put32(uint8_t *p, uint32_t v) {
    p[0] = v & 0xFF;
    p[1] = (v >> 8) & 0xFF;
    p[2] = (v >> 16) & 0xFF;
    p[3] = (v >> 24) & 0xFF;
}

static uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void ripple_handle(uint8_t *data, uint8_t length) {
    uint8_t sub = data[1];
    uint8_t id  = data[2];
    const ripple_param_meta_t *m;

    switch (sub) {
        case RIPPLE_SUB_IDENTIFY:
            // The only positive proof that THIS firmware is running.
            ripple_reply(data, sub, RIPPLE_OK, 0);
            data[4] = RIPPLE_MAGIC0;
            data[5] = RIPPLE_MAGIC1;
            data[6] = RIPPLE_MAGIC2;
            data[7] = RIPPLE_PROTO_VERSION;
            data[8] = RIPPLE_CONFIG_VERSION;
            data[9] = RIPPLE_NPARAMS;
            break;
        case RIPPLE_SUB_GET:
            m = ripple_meta(id);
            if (!m) {
                ripple_reply(data, sub, RIPPLE_EBADID, id);
                break;
            }
            ripple_reply(data, sub, RIPPLE_OK, id);
            put32(&data[4], ripple_get(id));
            put32(&data[8], m->min);   // ranges come FROM the firmware, so a
            put32(&data[12], m->max);  // host can never drift out of step
            break;
        case RIPPLE_SUB_SET:
            m = ripple_meta(id);
            if (!m) {
                ripple_reply(data, sub, RIPPLE_EBADID, id);
                break;
            }
            {
                uint32_t v = get32(&data[3 + 1]);
                if (v < m->min || v > m->max) {
                    // Refuse, do NOT clamp: a silently adjusted value is a
                    // lie about what was asked for. The host reports the
                    // range and the value it tried.
                    ripple_reply(data, sub, RIPPLE_ERANGE, id);
                    put32(&data[4], ripple_get(id));
                    put32(&data[8], m->min);
                    put32(&data[12], m->max);
                    break;
                }
                ripple_set(id, v);
                ripple_reply(data, sub, RIPPLE_OK, id);
                put32(&data[4], ripple_get(id));
            }
            break;
        case RIPPLE_SUB_SAVE:
            ripple_config_save();
            ripple_reply(data, sub, RIPPLE_OK, 0);
            break;
        case RIPPLE_SUB_RESET:
            // Back to the compiled-in defaults, in RAM. Persisting that is a
            // separate, deliberate SAVE.
            ripple_config_defaults();
            ripple_reply(data, sub, RIPPLE_OK, 0);
            break;
        default:
            ripple_reply(data, sub, RIPPLE_EBADCMD, id);
            break;
    }
    raw_hid_send(data, length);
}

void raw_hid_receive(uint8_t *data, uint8_t length) {
    if (data[0] == RIPPLE_PREFIX) {
        ripple_handle(data, length);
        return;
    }
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
