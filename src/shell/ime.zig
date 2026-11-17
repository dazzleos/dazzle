//! The system's input method (Chinese by pinyin, Japanese by romaji; see
//! input_method/input_method.zig), run by the shell for the app that has
//! the keyboard, in the text field it has enabled (`zwp_text_input_v3`).
//! Each key goes to it before the app: what it takes the app does not get;
//! what it composes goes to the app as the input method's preedit, and what
//! it puts in as its commit. Its candidates show in a panel by the text's
//! cursor. The keyboard layout says which language it composes; with
//! others, it takes nothing. Never in a password field. (Emoji by name are
//! the apps' own: kete's text fields have them.)

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");
const server_mod = @import("server.zig");
const keyboard = @import("keyboard.zig");
const kete_panel = @import("kete_panel.zig");
const p = @import("wayland").protocol;

const input_method = @import("input_method/input_method.zig");
const conversion = @import("input_method/conversion.zig");
const sys = @import("sys");
const Server = server_mod.Server;
const TextInput = server_mod.TextInput;

pub const Ime = struct {
    im: input_method.InputMethod = .{},
    /// The text input it composes for.
    target: ?*TextInput = null,
    /// The candidates' panel (none: they are not shown).
    panel: ?*kete_panel.Panel = null,
    /// The candidates changed since they were last drawn (or hidden).
    changed: bool = false,
    /// Where the text's cursor was when they were: the app says where it
    /// is after each change, a little later, so they move with it.
    drawn_at: server_mod.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// The keys it took as they went down: it takes them coming up too.
    taken: std.StaticBitSet(256) = .empty,
    /// The Japanese language pack's files, mapped (its pages read from the
    /// card as they are used), and its dictionary, once it is installed.
    japanese: ?struct { dict: sys.files.Mapped, conn: sys.files.Mapped } = null,
    dictionary: conversion.Dictionary = undefined,

    /// Offers a key (a Linux key code) to the input method, before the
    /// app with the keyboard gets it, after `s.modifiers` has noted it.
    /// Returns whether it took the key: the app is not to get it.
    pub fn key(ime: *Ime, s: *Server, code: u32, pressed: bool) bool {
        const was_taken = code < 256 and ime.taken.isSet(code);
        if (code < 256) ime.taken.unset(code);
        const took = ime.offer(s, code, pressed);
        if (took and pressed and code < 256) ime.taken.set(code);
        return took or (!pressed and was_taken);
    }

    fn offer(ime: *Ime, s: *Server, code: u32, pressed: bool) bool {
        const ti = s.activeTextInput() orelse {
            ime.drop();
            return false;
        };
        if (ti != ime.target) {
            ime.drop();
            ime.target = ti;
        }
        if (secret(ti)) return false;
        ime.im.language = switch (s.keyboard_layout) {
            .pinyin => .pinyin,
            .romaji => .romaji,
            else => .none,
        };
        if (ime.im.language == .romaji and ime.im.composing == null) ime.loadJapanese();
        // Other keyboards: nothing to compose.
        if (ime.im.language == .none and ime.im.composing == null) return false;
        const m = &s.modifiers;
        const shift = m.held[0] > 0;
        const ctrl = m.held[1] > 0;
        const caps = m.locked & keyboard.lock != 0;
        const altgr = m.held[4] > 0;
        const k: kete.ui.widget.Event.Key = .{
            .key = kete.window.evdev.keyOf(code),
            .pressed = pressed,
            .char = if (ctrl) null else s.keyboard_layout.char(code, shift, caps, altgr),
            .ctrl = ctrl,
            .shift = shift,
        };
        const out = ime.im.key(k);
        ime.send(s, out);
        return out.taken;
    }

    /// Sends what the input method put in and composes to the text input.
    fn send(ime: *Ime, s: *Server, out: input_method.InputMethod.Outcome) void {
        if (out.taken or out.commit != null or out.preedit) ime.changed = true;
        if (out.commit == null and !out.preedit) return;
        if (out.commit) |c| s.textInputCommitString(c);
        // Each `done` clears the preedit unless it is sent again; the
        // phrase being converted is marked (its "cursor").
        if (ime.im.composing != null) {
            const text = ime.im.composed();
            const m = ime.im.marked();
            s.textInputPreedit(text, @intCast(m.begin), @intCast(m.end));
        }
        s.textInputDone();
    }

    /// Maps the Japanese language pack's dictionary, if it is installed and
    /// not yet mapped, for the input method to convert with.
    fn loadJapanese(ime: *Ime) void {
        if (ime.japanese != null) return;
        const dir = sys.system.apps_dir ++ "/dazzle-language-ja/";
        const dict = sys.files.Mapped.open(dir ++ "ja.dict") catch return;
        const conn = sys.files.Mapped.open(dir ++ "ja.conn") catch {
            dict.close();
            return;
        };
        ime.dictionary = conversion.Dictionary.init(dict.data, conn.data) catch {
            sys.print(sys.log_warning ++ "dazzle-shell: the Japanese language pack's dictionary is damaged\n", .{});
            dict.close();
            conn.close();
            return;
        };
        ime.japanese = .{ .dict = dict, .conn = conn };
        ime.im.dictionary = &ime.dictionary;
        sys.print("dazzle-shell: converting Japanese with the language pack's dictionary\n", .{});
    }

    /// Stops composing, without putting anything in: the text input it
    /// was for has gone (or lost the keyboard).
    pub fn drop(ime: *Ime) void {
        if (ime.im.composing != null) {
            _ = ime.im.finish();
            ime.changed = true;
        }
        ime.target = null;
    }

    /// Whether candidates show.
    pub fn showing(ime: *const Ime) bool {
        return ime.target != null and ime.im.showing();
    }

    /// The candidates' picture and where it goes (by the text's cursor),
    /// if they changed and show; null if they did not change. Sets
    /// `hidden` when they no longer show.
    pub fn draw(ime: *Ime, s: *Server, now: u64, scale: f32, hidden: *bool) ?Candidates {
        // The app lost the keyboard, or its text field went.
        if (ime.target != null and s.activeTextInput() != ime.target) ime.drop();
        if (ime.target) |ti| if (ime.showing() and !std.meta.eql(ti.cursor_rect, ime.drawn_at)) {
            ime.changed = true;
        };
        if (!ime.changed) return null;
        ime.changed = false;
        if (!ime.showing()) {
            hidden.* = true;
            return null;
        }
        const ti = ime.target.?;
        const panel = ime.panel orelse return null;
        const surf = s.keyboard_focus orelse return null;
        const origin = s.surfaceOrigin(surf) orelse return null;
        const view: View = .{ .im = &ime.im, .scale = scale };
        const size = panel.naturalSize(view);
        const picture = panel.draw(size[0], size[1], now, view);
        if (picture.isEmpty()) return null;
        // Under the cursor, on the screen; above it if there is no room.
        const r = ti.cursor_rect;
        ime.drawn_at = r;
        const w: i32 = @intCast(size[0]);
        const h: i32 = @intCast(size[1]);
        const gap: i32 = @intFromFloat(@round(4 * scale));
        const sw: i32 = @intCast(s.output.width);
        const sh: i32 = @intCast(s.output.height);
        var x = origin[0] + r.x;
        var y = origin[1] + r.y + @as(i32, @intCast(r.height)) + gap;
        if (y + h > sh) y = origin[1] + r.y - gap - h;
        x = std.math.clamp(x, 0, @max(0, sw - w));
        y = std.math.clamp(y, 0, @max(0, sh - h));
        return .{ .picture = picture, .x = x, .y = y };
    }

    pub const Candidates = struct { picture: kete_panel.Picture, x: i32, y: i32 };
};

/// A text field for a password (or PIN): nothing is composed in it.
fn secret(ti: *const TextInput) bool {
    const purpose = ti.content_purpose;
    if (purpose == p.zwp_text_input_v3.content_purpose.password or purpose == p.zwp_text_input_v3.content_purpose.pin) return true;
    return ti.content_hint & p.zwp_text_input_v3.content_hint.sensitive_data != 0;
}

/// The candidates, one to a row: a character (or kana) and its number,
/// which types it.
const View = struct {
    im: *const input_method.InputMethod,
    scale: f32,

    pub fn build(v: *const View, cx: *kete.BuildContext) kete.Widget {
        const a = cx.arena;
        const t = cx.theme();
        const s = v.scale;
        const im = v.im;
        const rows = a.alloc(kete.Widget, im.count) catch return cx.make(kete.Column{});
        for (im.candidates[0..im.count], rows, 0..) |cand, *row, i| {
            const text = cx.make(kete.Text{ .text = cand.text, .style = .{ .size = @round(22 * s), .color = t.on_surface }, .wrap = false, .ellipsis = true });
            const children: []const kete.Widget = &.{
                cx.make(kete.Text{ .text = cx.fmt("{d}", .{i + 1}), .style = .{ .size = @round(14 * s), .color = t.on_surface_variant }, .wrap = false }),
                cx.make(kete.Expanded{ .child = text }),
            };
            row.* = cx.make(kete.RoundedBox{
                .color = if (i == im.selected) t.secondary_container else kete.gfx.Color.argb(0),
                .radius = .all(@round(8 * s)),
                .child = cx.make(kete.Padding{ .padding = .{ .left = @round(10 * s), .right = @round(12 * s), .top = @round(4 * s), .bottom = @round(4 * s) }, .child = cx.make(kete.Row{
                    .cross_axis_alignment = .center,
                    .spacing = @round(10 * s),
                    .children = a.dupe(kete.Widget, children) catch &.{},
                }) }),
            });
        }
        // Kana can be a phrase.
        const width: f32 = if (im.composing == .kana) 260 else 140;
        return cx.make(kete.SizedBox{ .width = @round(width * s), .child = cx.make(kete.RoundedBox{
            .color = t.surface_container_highest,
            .border_width = 1,
            .border_color = t.outline_variant,
            .radius = .all(@round(12 * s)),
            .child = cx.make(kete.Padding{ .padding = .all(@round(4 * s)), .child = cx.make(kete.Column{
                .cross_axis_alignment = .stretch,
                .fill = false,
                .children = rows,
            }) }),
        }) });
    }
};
