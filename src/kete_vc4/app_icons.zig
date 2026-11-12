//! The icons the apps' catalogue names (build.zig's apps), which Setup and
//! Settings show by name (`kete.IconName.fromName`): kete's icon font has
//! only the icons its apps' sources name, and these are named at run time.
//! Keep it in step with the apps' `.icon`s in build.zig.

const kete = @import("kete");

pub const icons = [_]kete.IconName{ .chat, .code, .edit_note, .folder, .landscape, .photo_camera, .public, .show_chart, .terminal, .view_in_ar, .apps };
