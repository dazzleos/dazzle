//! The Material icons Dazzle uses, by their Material names (see
//! fonts/MaterialIcons-Regular.codepoints). Only these are in the icon
//! font built into the programs: tools/subset_icons.zig makes it, with
//! just their glyphs, from the full font (as Flutter leaves out the icons
//! an app does not use). To use another icon, add its name here.

pub const Icon = enum {
    // Windows' title bars.
    close,
    crop_square,
    filter_none,
    // Controls.
    check,
    arrow_back,
    arrow_forward,
    arrow_upward,
    chevron_right,
    expand_more,
    // Files.
    home,
    folder,
    description,
    terminal,
    memory,
    help_outline,
    link,
    link_off,
    lock,
    // Settings.
    settings,
    wifi,
    lan,
    speed,
    info,
    wifi_1_bar,
    wifi_2_bar,
    // The demo.
    view_in_ar,
    fast_rewind,
    fast_forward,
    pause,
    play_arrow,
    // Settings' apps.
    apps,
    download,
    delete,
    refresh,
    // The camera.
    photo_camera,
    no_photography,
};
