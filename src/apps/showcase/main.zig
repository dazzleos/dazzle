//! The Dazzle widget showcase: an interactive gallery showing all of the
//! `ui` toolkit's Material 3 widgets in use. Like `dazzle-demo`, it is built
//! into a `.tar.xz` bundle (`zig-out/apps/dazzle-showcase.tar.xz`) for
//! sideloading rather than listed in the store catalogue.
//!
//!     dazzle-showcase [font.ttf]
//!
//! It runs until it is stopped or its window is closed.

const std = @import("std");
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const ui = @import("ui");
const build_info = @import("build_info");
const view = @import("view.zig");

const print = sys.print;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    print("dazzle-showcase (build {s}) running\n", .{build_info.commit});

    run(init, font_path) catch |err| {
        print(sys.log_error ++ "dazzle-showcase: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Widget Showcase",
        .app_id = "dazzle-showcase",
        .size = view.open_size,
        .min_size = view.min_size,
        .font_path = font_path,
    });
    defer a.close();

    var doc = try ui.TextDocument.init(gpa, view.initial_notes);
    defer doc.deinit();

    while (try a.step(60 * std.time.ns_per_s)) {
        const now = sys.nowNs();
        a.takeInput();
        try a.draw(now, view.Showcase{ .doc = &doc });
    }
}

test {
    _ = view;
}
