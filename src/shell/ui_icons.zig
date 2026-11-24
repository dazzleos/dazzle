//! The icons the shell's kete UI shows, and the way from Dazzle's icons
//! (`icons.Icon`) to kete's. Apps name their icon in a file, so any of
//! Dazzle's may be wanted: kete's icon font has only the icons named in the
//! source (see its scan_icons), so they are all named here.

const std = @import("std");
const kete = @import("kete");
const icons = @import("icons");

comptime {
    _ = &[_]kete.IconName{
        .close, .crop_square, .filter_none, .check, .arrow_back, .arrow_forward, .arrow_upward,
        .chevron_right, .expand_more, .visibility, .visibility_off, .person, .folder,
        .description, .terminal, .memory, .help_outline, .link, .link_off, .lock,
        .sort_by_alpha, .schedule, .grid_view, .view_list, .create_new_folder, .warning, .usb,
        .content_paste, .eject, .settings, .wifi, .lan, .speed, .info, .developer_board,
        .settings_input_component, .language, .keyboard, .mouse, .device_hub, .headphones,
        .videocam, .print, .sports_esports, .article, .wifi_1_bar, .wifi_2_bar,
        .signal_wifi_0_bar, .network_wifi_1_bar, .network_wifi_2_bar, .network_wifi_3_bar,
        .signal_wifi_4_bar, .signal_wifi_off, .wifi_tethering, .public_off, .arrow_downward,
        .system_update_alt, .wifi_password, .view_in_ar, .fast_rewind, .fast_forward, .pause,
        .play_arrow, .apps, .download, .delete, .refresh, .restart_alt, .photo_camera,
        .no_photography, .landscape, .person_add, .computer, .show_chart, .fiber_manual_record,
        .stop, .save, .add, .zoom_in, .zoom_out, .delete_sweep, .edit_note, .edit, .note_add,
        .public, .layers, .my_location, .fullscreen, .fullscreen_exit, .code, .chat, .forum,
        .group, .logout, .send, .volume_up, .volume_down, .volume_mute, .volume_off, .speaker,
        .tv, .music_note, .audio_file, .palette, .dark_mode, .light_mode, .power_settings_new,
        .wifi_off, .screen_rotation, .keyboard_capslock, .backspace, .space_bar,
        .keyboard_return, .keyboard_hide,
    };
}

/// Dazzle's icon `i`, as kete's.
pub fn of(i: icons.Icon) kete.IconName {
    return switch (i) {
        inline else => |t| if (@hasField(kete.IconName, @tagName(t))) @field(kete.IconName, @tagName(t)) else .help_outline,
    };
}

test "every icon of Dazzle's is in kete's icon font" {
    inline for (comptime std.enums.values(icons.Icon)) |i| try std.testing.expect(@hasField(kete.IconName, @tagName(i)));
}
