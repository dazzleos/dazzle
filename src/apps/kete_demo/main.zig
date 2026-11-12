//! A prototype of a Dazzle app built with kete, drawn by Dazzle's vc4
//! renderer (`kete_vc4`): a few of kete's widgets, to try how kete runs on
//! a Pi.
//!
//!     dazzle-kete-demo
//!
//! Set KETE_TRACE=1 to log how long each frame takes to build and present.

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const build_info = @import("build_info");

const print = sys.print;

const Demo = struct {
    pub const State = struct {
        count: i32 = 0,
        on: bool = true,
        level: f32 = 0.5,

        pub fn increment(s: *State) void {
            s.count += 1;
        }

        pub fn decrement(s: *State) void {
            s.count -= 1;
        }

        pub fn setOn(s: *State, on: bool) void {
            s.on = on;
        }

        pub fn setLevel(s: *State, level: f32) void {
            s.level = level;
        }
    };

    pub fn build(_: *const Demo, cx: *kete.BuildContext, state: *State) kete.Widget {
        return cx.make(kete.Align.center(cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 16,
            .children = cx.makeAll(.{
                kete.Text{ .text = "Hello from kete on Dazzle!" },
                kete.Text{ .text = cx.fmt("Count: {d}", .{state.count}) },
                kete.Row{
                    .fill = false,
                    .spacing = 12,
                    .children = cx.makeAll(.{
                        kete.OutlinedButton{ .icon = .remove, .on_press = .of(state, State.decrement) },
                        kete.FilledButton{ .icon = .add, .label = "Add", .on_press = .of(state, State.increment) },
                    }),
                },
                kete.SwitchRow{ .label = "Switch", .value = state.on, .on_changed = .of(state, State.setOn) },
                kete.SizedBox{ .width = 320, .child = cx.make(kete.Slider{ .value = state.level, .on_changed = .of(state, State.setLevel) }) },
                kete.TextField{ .placeholder = "Type here" },
            }),
        })));
    }
};

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    print("dazzle-kete-demo (build {s}) running\n", .{build_info.commit});
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-kete-demo: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var host: kete_vc4.Host = undefined;
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-kete-demo" });
    defer host.deinit();
    const root: Demo = .{};
    _ = try host.app.openWindow(.{
        .title = "Kete Demo",
        .root = .of(&root),
        .size = .{ 640, 480 },
        .on_close_request = .close,
    });
    try host.app.run();
}
