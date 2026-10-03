//! The Wayland interfaces Stardust uses: names, versions and opcodes, from
//! wayland.xml, xdg-shell.xml and linux-dmabuf-v1.xml. Requests are sent by
//! clients, events by the server; each list starts at opcode 0.

pub const wl_display = struct {
    pub const name = "wl_display";
    pub const id: u32 = 1;
    pub const request = struct {
        pub const sync = 0;
        pub const get_registry = 1;
    };
    pub const event = struct {
        pub const @"error" = 0;
        pub const delete_id = 1;
    };
    pub const err = struct {
        pub const invalid_object = 0;
        pub const invalid_method = 1;
        pub const no_memory = 2;
        pub const implementation = 3;
    };
};

pub const wl_registry = struct {
    pub const name = "wl_registry";
    pub const request = struct {
        pub const bind = 0;
    };
    pub const event = struct {
        pub const global = 0;
        pub const global_remove = 1;
    };
};

pub const wl_callback = struct {
    pub const name = "wl_callback";
    pub const event = struct {
        pub const done = 0;
    };
};

pub const wl_compositor = struct {
    pub const name = "wl_compositor";
    pub const version = 4;
    pub const request = struct {
        pub const create_surface = 0;
        pub const create_region = 1;
    };
};

pub const wl_surface = struct {
    pub const name = "wl_surface";
    pub const request = struct {
        pub const destroy = 0;
        pub const attach = 1;
        pub const damage = 2;
        pub const frame = 3;
        pub const set_opaque_region = 4;
        pub const set_input_region = 5;
        pub const commit = 6;
        pub const set_buffer_transform = 7;
        pub const set_buffer_scale = 8;
        pub const damage_buffer = 9;
    };
    pub const err = struct {
        pub const invalid_scale = 0;
        pub const invalid_transform = 1;
        pub const invalid_size = 2;
    };
};

pub const wl_region = struct {
    pub const name = "wl_region";
    pub const request = struct {
        pub const destroy = 0;
        pub const add = 1;
        pub const subtract = 2;
    };
};

pub const wl_buffer = struct {
    pub const name = "wl_buffer";
    pub const request = struct {
        pub const destroy = 0;
    };
    pub const event = struct {
        pub const release = 0;
    };
};

pub const wl_shm = struct {
    pub const name = "wl_shm";
    pub const version = 1;
    pub const request = struct {
        pub const create_pool = 0;
    };
    pub const event = struct {
        pub const format = 0;
    };
    pub const format = struct {
        pub const argb8888 = 0;
        pub const xrgb8888 = 1;
    };
    pub const err = struct {
        pub const invalid_format = 0;
        pub const invalid_stride = 1;
        pub const invalid_fd = 2;
    };
};

pub const wl_shm_pool = struct {
    pub const name = "wl_shm_pool";
    pub const request = struct {
        pub const create_buffer = 0;
        pub const destroy = 1;
        pub const resize = 2;
    };
};

pub const xdg_wm_base = struct {
    pub const name = "xdg_wm_base";
    pub const version = 1;
    pub const request = struct {
        pub const destroy = 0;
        pub const create_positioner = 1;
        pub const get_xdg_surface = 2;
        pub const pong = 3;
    };
    pub const event = struct {
        pub const ping = 0;
    };
    pub const err = struct {
        pub const role = 0;
        pub const defunct_surfaces = 1;
        pub const not_the_topmost_popup = 2;
        pub const invalid_popup_parent = 3;
        pub const invalid_surface_state = 4;
        pub const invalid_positioner = 5;
    };
};

pub const xdg_surface = struct {
    pub const name = "xdg_surface";
    pub const request = struct {
        pub const destroy = 0;
        pub const get_toplevel = 1;
        pub const get_popup = 2;
        pub const set_window_geometry = 3;
        pub const ack_configure = 4;
    };
    pub const event = struct {
        pub const configure = 0;
    };
    pub const err = struct {
        pub const not_constructed = 1;
        pub const already_constructed = 2;
        pub const unconfigured_buffer = 3;
    };
};

pub const xdg_toplevel = struct {
    pub const name = "xdg_toplevel";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_parent = 1;
        pub const set_title = 2;
        pub const set_app_id = 3;
        pub const show_window_menu = 4;
        pub const move = 5;
        pub const resize = 6;
        pub const set_max_size = 7;
        pub const set_min_size = 8;
        pub const set_maximized = 9;
        pub const unset_maximized = 10;
        pub const set_fullscreen = 11;
        pub const unset_fullscreen = 12;
        pub const set_minimized = 13;
    };
    pub const event = struct {
        pub const configure = 0;
        pub const close = 1;
    };
    pub const state = struct {
        pub const maximized = 1;
        pub const fullscreen = 2;
        pub const resizing = 3;
        pub const activated = 4;
    };
};

pub const zwp_linux_dmabuf_v1 = struct {
    pub const name = "zwp_linux_dmabuf_v1";
    pub const version = 3;
    pub const request = struct {
        pub const destroy = 0;
        pub const create_params = 1;
    };
    pub const event = struct {
        pub const format = 0;
        pub const modifier = 1;
    };
};

pub const zwp_linux_buffer_params_v1 = struct {
    pub const name = "zwp_linux_buffer_params_v1";
    pub const request = struct {
        pub const destroy = 0;
        pub const add = 1;
        pub const create = 2;
        pub const create_immed = 3;
    };
    pub const event = struct {
        pub const created = 0;
        pub const failed = 1;
    };
    pub const err = struct {
        pub const already_used = 0;
        pub const plane_idx = 1;
        pub const plane_set = 2;
        pub const incomplete = 3;
        pub const invalid_format = 4;
        pub const invalid_dimensions = 5;
        pub const out_of_bounds = 6;
        pub const invalid_wl_buffer = 7;
    };
};

/// DRM fourcc codes (drm_fourcc.h).
pub const fourcc = struct {
    fn code(s: *const [4]u8) u32 {
        return @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
    }
    pub const xrgb8888 = code("XR24");
    pub const argb8888 = code("AR24");
};

/// DRM format modifiers (drm_fourcc.h).
pub const modifier = struct {
    pub const linear: u64 = 0;
    /// The VideoCore IV's tiled "T" layout, which its texture unit reads
    /// and its tile buffer can write.
    pub const broadcom_vc4_t_tiled: u64 = 0x07 << 56 | 1;
};

pub const wl_seat = struct {
    pub const name = "wl_seat";
    pub const version = 5;
    pub const request = struct {
        pub const get_pointer = 0;
        pub const get_keyboard = 1;
        pub const get_touch = 2;
        pub const release = 3;
    };
    pub const event = struct {
        pub const capabilities = 0;
        pub const name = 1;
    };
    pub const capability = struct {
        pub const pointer = 1;
        pub const keyboard = 2;
        pub const touch = 4;
    };
};

pub const wl_pointer = struct {
    pub const name = "wl_pointer";
    pub const request = struct {
        pub const set_cursor = 0;
        pub const release = 1;
    };
    pub const event = struct {
        pub const enter = 0;
        pub const leave = 1;
        pub const motion = 2;
        pub const button = 3;
        pub const axis = 4;
        pub const frame = 5;
        pub const axis_source = 6;
        pub const axis_stop = 7;
        pub const axis_discrete = 8;
    };
    pub const button_state = struct {
        pub const released = 0;
        pub const pressed = 1;
    };
    pub const axis = struct {
        pub const vertical_scroll = 0;
        pub const horizontal_scroll = 1;
    };
};

pub const wl_keyboard = struct {
    pub const name = "wl_keyboard";
    pub const request = struct {
        pub const release = 0;
    };
    pub const event = struct {
        pub const keymap = 0;
        pub const enter = 1;
        pub const leave = 2;
        pub const key = 3;
        pub const modifiers = 4;
        pub const repeat_info = 5;
    };
    pub const keymap_format = struct {
        /// Raw Linux evdev key codes, without an XKB keymap.
        pub const no_keymap = 0;
        pub const xkb_v1 = 1;
    };
    pub const key_state = struct {
        pub const released = 0;
        pub const pressed = 1;
    };
};

/// Linux input event codes (linux/input-event-codes.h) used by Stardust.
pub const input = struct {
    pub const btn_left = 0x110;
    pub const btn_right = 0x111;
    pub const btn_middle = 0x112;
};
