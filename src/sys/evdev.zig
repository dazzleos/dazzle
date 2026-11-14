//! Linux input event codes (linux/input-event-codes.h): the event types,
//! keys and buttons, and axes the kernel's evdev devices report, which the
//! shell passes on to Wayland clients as they are. Named as in the header,
//! in lower case; only those Dazzle uses.

// Event types.
pub const ev_syn = 0x00;
pub const ev_key = 0x01;
pub const ev_rel = 0x02;
pub const ev_abs = 0x03;

// Synchronization events.
pub const syn_report = 0;

// Keys: their places on the keyboard, whatever the layout.
pub const key_esc = 1;
pub const key_1 = 2;
pub const key_9 = 10;
pub const key_0 = 11;
pub const key_backspace = 14;
pub const key_w = 17;
pub const key_e = 18;
pub const key_y = 21;
pub const key_i = 23;
pub const key_leftctrl = 29;
pub const key_a = 30;
pub const key_s = 31;
pub const key_d = 32;
pub const key_leftshift = 42;
pub const key_x = 45;
pub const key_c = 46;
pub const key_v = 47;
pub const key_n = 49;
pub const key_rightshift = 54;
pub const key_space = 57;
pub const key_capslock = 58;
pub const key_rightctrl = 97;
/// Print Screen.
pub const key_sysrq = 99;
pub const key_rightalt = 100;
pub const key_up = 103;
pub const key_left = 105;
pub const key_right = 106;
pub const key_down = 108;
pub const key_delete = 111;
pub const key_leftmeta = 125;
pub const key_rightmeta = 126;

// Buttons: keyboard keys are below the first.
pub const btn_misc = 0x100;
pub const btn_mouse = 0x110;
pub const btn_left = 0x110;
pub const btn_right = 0x111;
pub const btn_middle = 0x112;
pub const btn_side = 0x113;
pub const btn_extra = 0x114;
pub const btn_task = 0x117;
pub const btn_touch = 0x14a;

// Relative axes.
pub const rel_x = 0x00;
pub const rel_y = 0x01;
pub const rel_hwheel = 0x06;
pub const rel_wheel = 0x08;

// Absolute axes.
pub const abs_x = 0x00;
pub const abs_y = 0x01;
pub const abs_mt_slot = 0x2f;
pub const abs_mt_position_x = 0x35;
pub const abs_mt_position_y = 0x36;
pub const abs_mt_tracking_id = 0x39;
