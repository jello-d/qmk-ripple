RGB_MATRIX_CUSTOM_USER = yes
RAW_ENABLE = yes    # 0xFF60 raw-HID interface for host control
SRC += hostctl.c    # raw_hid_receive: backlight off/on for panel-power
