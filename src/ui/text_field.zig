//! TextField: one line of text to type, Material's outlined text field.
//! Clicking it gives it the keyboard; typing, Backspace, Delete, the arrow
//! keys, Home and End edit it; Enter submits. With `obscure` (for
//! passwords) it shows dots. ASCII only, for now.

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const keymap = @import("keymap.zig");
const btn_left = @import("widgets.zig").btn_left;

const Node = widget.Node;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Constraints = geometry.Constraints;
const Size = geometry.Size;

pub const TextField = struct {
    /// Shown, dimmed, while it is empty.
    placeholder: []const u8 = "",
    /// Dots instead of the characters (for passwords).
    obscure: bool = false,
    max_len: usize = 63,
    width: f32 = 240,
    /// Text size; the theme's body size if null.
    size: ?f32 = null,
    on_changed: ?widget.ValueCallback([]const u8) = null,
    /// Enter was pressed.
    on_submit: ?widget.Callback = null,

    pub const capacity = 128;

    pub const State = struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,
        /// Where typing goes: a byte index.
        cursor: usize = 0,
        focused: bool = false,
        hovered: bool = false,

        pub fn text(s: *const State) []const u8 {
            return s.buf[0..s.len];
        }

        fn insert(s: *State, c: u8, max: usize) bool {
            if (s.len >= @min(max, capacity)) return false;
            std.mem.copyBackwards(u8, s.buf[s.cursor + 1 .. s.len + 1], s.buf[s.cursor..s.len]);
            s.buf[s.cursor] = c;
            s.len += 1;
            s.cursor += 1;
            return true;
        }

        fn removeAt(s: *State, i: usize) void {
            std.mem.copyForwards(u8, s.buf[i .. s.len - 1], s.buf[i + 1 .. s.len]);
            s.len -= 1;
        }

        /// Edits for a key; returns whether the text changed.
        fn key(s: *State, k: Event.Key, max: usize) bool {
            switch (k.code) {
                keymap.backspace => if (s.cursor > 0) {
                    s.cursor -= 1;
                    s.removeAt(s.cursor);
                    return true;
                },
                keymap.delete => if (s.cursor < s.len) {
                    s.removeAt(s.cursor);
                    return true;
                },
                keymap.left => s.cursor -|= 1,
                keymap.right => s.cursor = @min(s.cursor + 1, s.len),
                keymap.home => s.cursor = 0,
                keymap.end => s.cursor = s.len,
                else => if (k.char) |c| return s.insert(c, max),
            }
            return false;
        }
    };

    const height = 44;
    const pad = 14;
    const dot = "•";

    fn fontStyle(self: *const TextField, n: *const Node) ?font.Style {
        const f = n.ui.font orelse return null;
        return .{ .font = f, .size = self.size orelse n.ui.theme.body_size };
    }

    pub fn layout(self: *const TextField, n: *Node, c: Constraints) Size {
        const s = self.fontStyle(n);
        const h: f32 = if (s) |st| @max(height, @ceil(st.lineHeight() + 20)) else height;
        return c.constrain(.{ .w = self.width, .h = h });
    }

    /// What is shown for the first `n` characters.
    fn shown(self: *const TextField, buf: []u8, text: []const u8) []const u8 {
        if (!self.obscure) return text;
        const count = @min(text.len, buf.len / dot.len);
        for (0..count) |i| @memcpy(buf[i * dot.len ..][0..dot.len], dot);
        return buf[0 .. count * dot.len];
    }

    pub fn paint(self: *const TextField, n: *Node, p: *Painter) void {
        const t = &n.ui.theme;
        const st = n.state(State);
        const c = p.canvas();
        const r: gfx.Rect = .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h };
        if (st.focused) {
            c.strokeRoundedRect(r.outset(-1), .all(4), 2, t.primary);
        } else {
            c.strokeRoundedRect(r.outset(-0.5), .all(4), 1, if (st.hovered) t.on_surface else t.outline);
        }
        const style = self.fontStyle(n) orelse return;
        const baseline = @round((n.size.h - style.lineHeight()) / 2 + style.ascent());
        var buf: [capacity * dot.len]u8 = undefined;
        const text = self.shown(&buf, st.text());
        var before_buf: [capacity * dot.len]u8 = undefined;
        const before = self.shown(&before_buf, st.text()[0..st.cursor]);
        const cursor_x = font.measure(style, before);
        // Long text scrolls to keep the cursor in view.
        const room = n.size.w - 2 * pad;
        const scroll = @max(cursor_x - room, 0);
        const old = p.clipTo(.{ .x = pad - 2, .y = 0, .w = room + 4, .h = n.size.h });
        defer p.restoreClip(old);
        if (st.len == 0 and !st.focused) {
            _ = p.text(style.size, pad, baseline, self.placeholder, t.on_surface_variant);
        } else {
            _ = p.text(style.size, pad - scroll, baseline, text, t.on_surface);
        }
        if (st.focused) {
            const x = @round(pad - scroll + cursor_x);
            c.fillRect(.{ .x = x, .y = baseline - style.ascent(), .w = 2, .h = style.lineHeight() }, t.primary);
        }
    }

    pub fn event(self: *const TextField, n: *Node, e: Event) bool {
        const st = n.state(State);
        switch (e) {
            .enter => st.hovered = true,
            .leave => st.hovered = false,
            .press => |pr| {
                if (pr.button != btn_left) return false;
                n.ui.focus(n);
                st.cursor = self.cursorAt(n, pr.pos[0]);
                return true;
            },
            .release => return true,
            .focus => st.focused = true,
            .blur => st.focused = false,
            .key => |k| {
                if (!k.pressed) return true;
                if (k.code == keymap.enter or k.code == keymap.keypad_enter) {
                    if (self.on_submit) |f| f.call();
                    return true;
                }
                if (st.key(k, self.max_len)) if (self.on_changed) |f| f.call(st.text());
                return true;
            },
            .motion, .scroll => {},
        }
        return false;
    }

    /// The character boundary nearest `x` (in the widget).
    fn cursorAt(self: *const TextField, n: *const Node, x: f32) usize {
        const st = n.state(State);
        const style = self.fontStyle(n) orelse return st.len;
        var buf: [capacity * dot.len]u8 = undefined;
        var best: usize = 0;
        var best_d = std.math.inf(f32);
        for (0..st.len + 1) |i| {
            const w = font.measure(style, self.shown(&buf, st.text()[0..i]));
            const d = @abs(pad + w - x);
            if (d < best_d) {
                best = i;
                best_d = d;
            }
        }
        return best;
    }
};

const testing = std.testing;

test "typing into a text field" {
    const Ui = @import("runtime.zig").Ui;
    const widgets = @import("widgets.zig");
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();
    const Sink = struct {
        text: [64]u8 = undefined,
        len: usize = 0,
        submitted: u32 = 0,
        fn changed(s: *@This(), t: []const u8) void {
            @memcpy(s.text[0..t.len], t);
            s.len = t.len;
        }
        fn submit(s: *@This()) void {
            s.submitted += 1;
        }
    };
    var sink: Sink = .{};
    const App = struct {
        sink: *Sink,
        obscure: bool,
        pub fn build(self: *const @This(), cx: *widget.Context) widget.Widget {
            return cx.make(widgets.Padding{ .padding = .all(20), .child = cx.make(widgets.Column{ .cross_axis_alignment = .start, .children = &.{
                cx.make(TextField{ .placeholder = "Password", .obscure = self.obscure, .on_changed = .of(self.sink, Sink.changed), .on_submit = .of(self.sink, Sink.submit) }),
            } }) });
        }
    };
    u.frame(400, 200, 0, App{ .sink = &sink, .obscure = false });
    const at: geometry.Point = .{ 40, 40 };
    u.pointerMotion(at);
    u.pointerButton(at, widgets.btn_left, true);
    u.pointerButton(at, widgets.btn_left, false);
    try testing.expect(u.focused != null);
    // Shift-A, b, 1, then Backspace, Left, X: "AXb".
    u.keyEvent(keymap.left_shift, true);
    for ([_]u32{ 30, 30 }, [_]bool{ true, false }) |code, down| u.keyEvent(code, down);
    u.keyEvent(keymap.left_shift, false);
    for ([_]u32{ 48, 2, keymap.backspace, keymap.left }) |code| {
        u.keyEvent(code, true);
        u.keyEvent(code, false);
    }
    u.keyEvent(keymap.left_shift, true);
    u.keyEvent(45, true);
    u.keyEvent(keymap.left_shift, false);
    try testing.expectEqualStrings("AXb", sink.text[0..sink.len]);
    u.keyEvent(keymap.enter, true);
    try testing.expectEqual(@as(u32, 1), sink.submitted);
    // It keeps its text between frames, and paints (obscured) without
    // overflowing.
    u.frame(400, 200, 1, App{ .sink = &sink, .obscure = true });
    var n = u.root.?;
    while (n.children.items.len > 0) n = n.children.items[0];
    try testing.expectEqualStrings("AXb", n.state(TextField.State).text());
    // Clicking elsewhere takes the keyboard away: keys go nowhere.
    u.pointerMotion(.{ 300, 150 });
    u.pointerButton(.{ 300, 150 }, widgets.btn_left, true);
    u.pointerButton(.{ 300, 150 }, widgets.btn_left, false);
    try testing.expect(u.focused == null);
    u.keyEvent(30, true);
    try testing.expectEqualStrings("AXb", sink.text[0..sink.len]);
}
