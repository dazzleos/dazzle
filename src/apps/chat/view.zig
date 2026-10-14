//! Chat's window, as widgets. Outside a room it lists the rooms found on
//! the network, to join, with a field and a button to start one. In a room
//! it shows who is there, what has been said in order (scrolled to the
//! newest), and a field to say something in. Its settings (the gear, in
//! either) change the name others see.

const std = @import("std");
const ui = @import("ui");
const net = @import("net.zig");
const protocol = @import("protocol.zig");

pub const min_size = [2]u32{ 420, 360 };
pub const open_size = [2]u32{ 800, 640 };

/// What the window asked for, for the app to do (see main.zig).
pub const Actions = struct {
    room_name_buf: [ui.TextField.capacity]u8 = undefined,
    room_name_len: usize = 0,
    draft_buf: [ui.TextField.capacity]u8 = undefined,
    draft_len: usize = 0,
    /// The message field starts again (empty) when this changes.
    draft_key: u64 = 1,
    create: bool = false,
    leave: bool = false,
    send: bool = false,
    /// A room to join (its id).
    join: ?u64 = null,
    dismiss: bool = false,
    /// The settings are shown, with the name being typed.
    settings_open: bool = false,
    name_buf: [ui.TextField.capacity]u8 = undefined,
    name_len: usize = 0,
    open_settings: bool = false,
    save_settings: bool = false,

    pub fn roomName(a: *const Actions) []const u8 {
        return a.room_name_buf[0..a.room_name_len];
    }

    pub fn draft(a: *const Actions) []const u8 {
        return a.draft_buf[0..a.draft_len];
    }

    fn setRoomName(a: *Actions, text: []const u8) void {
        a.room_name_len = copyText(&a.room_name_buf, text);
    }

    fn setDraft(a: *Actions, text: []const u8) void {
        a.draft_len = copyText(&a.draft_buf, text);
    }

    fn requestCreate(a: *Actions) void {
        a.create = true;
    }

    fn requestLeave(a: *Actions) void {
        a.leave = true;
    }

    fn requestSend(a: *Actions) void {
        a.send = true;
    }

    fn requestDismiss(a: *Actions) void {
        a.dismiss = true;
    }

    pub fn typedName(a: *const Actions) []const u8 {
        return a.name_buf[0..a.name_len];
    }

    pub fn setTypedName(a: *Actions, text: []const u8) void {
        a.name_len = copyText(&a.name_buf, text);
    }

    fn requestSettings(a: *Actions) void {
        a.open_settings = true;
    }

    fn requestSaveSettings(a: *Actions) void {
        a.save_settings = true;
    }

    fn closeSettings(a: *Actions) void {
        a.settings_open = false;
    }
};

/// Copies as much of `text` as fits (whole characters).
fn copyText(buf: []u8, text: []const u8) usize {
    var n = @min(text.len, buf.len);
    while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
    @memcpy(buf[0..n], text[0..n]);
    return n;
}

const JoinPress = struct {
    actions: *Actions,
    room: u64,

    fn press(j: *JoinPress) void {
        j.actions.join = j.room;
    }
};

pub const Chat = struct {
    /// This client's id, to tell its messages.
    node: u64,
    /// The rooms found.
    ads: []const net.Ad,
    /// The room it is in, if it is in one.
    room: ?*const net.Room,
    /// The people in it, this client first.
    members: []const []const u8 = &.{},
    /// Something to tell the person.
    message: []const u8 = "",
    /// What others see this client as.
    name: []const u8 = "",
    /// What the settings set it back to when cleared.
    default_name: []const u8 = "",
    actions: *Actions,

    pub fn build(self: *const Chat, cx: *ui.Context) ui.Widget {
        const body = if (self.room) |room| self.inRoom(cx, room) else self.lobby(cx);
        return cx.make(ui.Dialog{
            .open = self.actions.settings_open,
            .icon = .settings,
            .title = "Settings",
            .description = cx.fmt("The name others see you as. Leave it empty to use this computer's name ({s}).", .{self.default_name}),
            .content = cx.make(ui.TextField{
                .initial = self.name,
                .placeholder = self.default_name,
                .width = std.math.inf(f32),
                .max_len = protocol.max_name,
                .autofocus = true,
                .on_changed = .of(self.actions, Actions.setTypedName),
                .on_submit = .of(self.actions, Actions.requestSaveSettings),
            }),
            .confirm_label = "Save",
            .on_confirm = .of(self.actions, Actions.requestSaveSettings),
            .dismiss_label = "Cancel",
            .on_dismiss = .of(self.actions, Actions.closeSettings),
            .child = body,
        });
    }

    fn settingsButton(self: *const Chat, cx: *ui.Context) ui.Widget {
        return cx.make(ui.IconButton{ .icon = .settings, .on_press = .of(self.actions, Actions.requestSettings) });
    }

    fn lobby(self: *const Chat, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const a = cx.ui.arena();
        const list = if (self.ads.len == 0)
            cx.make(ui.Center{ .child = cx.make(ui.Padding{ .padding = .all(16), .child = cx.make(ui.Text{
                .text = "No rooms found. Start one and others on this network can join it.",
                .style = .{ .size = 16, .color = t.on_surface_variant },
                .text_align = .center,
            }) }) })
        else blk: {
            var rows: std.ArrayList(ui.Widget) = .empty;
            for (self.ads) |ad| {
                const press = a.create(JoinPress) catch break;
                press.* = .{ .actions = self.actions, .room = ad.room };
                rows.append(a, cx.make(ui.ListItem{
                    .leading_icon = .forum,
                    .headline = a.dupe(u8, ad.name.get()) catch "",
                    .supporting_text = if (ad.members == 1) "1 person" else cx.fmt("{d} people", .{ad.members}),
                    .on_press = .of(press, JoinPress.press),
                }).withKey(ad.room)) catch break;
            }
            break :blk cx.make(ui.ScrollView{ .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .spacing = 4,
                .children = rows.items,
            }) });
        };
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{ .title = "Chat" }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Snackbar{
                .message = self.message,
                .on_dismiss = .of(self.actions, Actions.requestDismiss),
                .child = cx.make(ui.Center{ .height_factor = 1, .child = cx.make(ui.ConstrainedBox{
                    .constraints = .{ .max_w = 560 },
                    .child = cx.make(ui.Padding{ .padding = .symmetric(12, 8), .child = cx.make(ui.Column{
                        .cross_axis_alignment = .stretch,
                        .spacing = 12,
                        .children = &.{
                            cx.make(ui.Row{ .spacing = 8, .cross_axis_alignment = .center, .children = &.{
                                cx.make(ui.Icon{ .icon = .person, .color = t.on_surface_variant }),
                                cx.make(ui.Expanded{ .child = cx.make(ui.Text{
                                    .text = cx.fmt("You are {s}", .{self.name}),
                                    .style = .{ .size = 16, .color = t.on_surface },
                                    .wrap = false,
                                    .ellipsis = true,
                                }) }),
                                self.settingsButton(cx),
                            } }),
                            cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                                cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                                    .placeholder = "Name for a new room",
                                    .width = std.math.inf(f32),
                                    .max_len = protocol.max_name,
                                    .autofocus = true,
                                    .on_changed = .of(self.actions, Actions.setRoomName),
                                    .on_submit = .of(self.actions, Actions.requestCreate),
                                }) }),
                                cx.make(ui.FilledButton{
                                    .label = "Start Room",
                                    .icon = .add,
                                    .on_press = .of(self.actions, Actions.requestCreate),
                                }),
                            } }),
                            cx.make(ui.Padding{ .padding = .{ .top = 4 }, .child = cx.make(ui.Text{
                                .text = "Rooms on this network",
                                .style = .{ .size = 16, .color = t.on_surface_variant },
                                .wrap = false,
                            }) }),
                            cx.make(ui.Divider{}),
                            cx.make(ui.Expanded{ .child = list }),
                        },
                    }) }),
                }) }),
            }) }),
        } });
    }

    fn inRoom(self: *const Chat, cx: *ui.Context, room: *const net.Room) ui.Widget {
        const t = cx.theme();
        const a = cx.ui.arena();
        const messages = room.log.items.items;

        var rows: std.ArrayList(ui.Widget) = .empty;
        for (messages, 0..) |m, i| {
            const mine = m.author == self.node;
            rows.append(a, cx.make(ui.Padding{ .padding = .symmetric(0, 5), .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .children = &.{
                    cx.make(ui.Text{
                        .text = if (mine) "You" else m.name,
                        .style = .{ .size = 14, .color = if (mine) t.primary else t.on_surface_variant },
                        .wrap = false,
                        .ellipsis = true,
                    }),
                    cx.make(ui.Text{ .text = m.text, .style = .{ .size = 18, .color = t.on_surface } }),
                },
            }) }).withKey(i + 1)) catch break;
        }
        if (messages.len == 0) rows.append(a, cx.make(ui.Padding{ .padding = .all(16), .child = cx.make(ui.Text{
            .text = "Nothing has been said yet.",
            .style = .{ .size = 16, .color = t.on_surface_variant },
            .text_align = .center,
        }) })) catch {};

        return cx.make(ui.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(ui.TitleBar{ .title = room.name.get() }),
                cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 }, .child = cx.make(ui.Row{
                    .spacing = 12,
                    .cross_axis_alignment = .center,
                    .children = &.{
                        cx.make(ui.TonalButton{
                            .label = "Leave",
                            .icon = .logout,
                            .on_press = .of(self.actions, Actions.requestLeave),
                        }),
                        cx.make(ui.Icon{ .icon = .group, .color = t.on_surface_variant }),
                        cx.make(ui.Expanded{ .child = cx.make(ui.Text{
                            .text = self.people(cx),
                            .style = .{ .size = 15, .color = t.on_surface_variant },
                            .wrap = false,
                            .ellipsis = true,
                        }) }),
                        self.settingsButton(cx),
                    },
                }) }),
                cx.make(ui.Divider{}),
                cx.make(ui.Expanded{
                    .child = cx.make(ui.Snackbar{
                        .message = self.message,
                        .on_dismiss = .of(self.actions, Actions.requestDismiss),
                        .child = cx.make(ui.ScrollView{
                            // Newest in view as they come.
                            .reveal = if (messages.len > 0) messages.len else null,
                            .child = cx.make(ui.Padding{ .padding = .symmetric(16, 8), .child = cx.make(ui.Column{
                                .cross_axis_alignment = .stretch,
                                .main_axis_size = .min,
                                .children = rows.items,
                            }) }),
                        }),
                    }),
                }),
                cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 12 }, .child = cx.make(ui.Row{
                    .spacing = 8,
                    .cross_axis_alignment = .center,
                    .children = &.{
                        cx.make(ui.Expanded{ .child = cx.make(ui.TextField{
                            .placeholder = "Say something",
                            .width = std.math.inf(f32),
                            .max_len = protocol.max_text,
                            .autofocus = true,
                            .on_changed = .of(self.actions, Actions.setDraft),
                            .on_submit = .of(self.actions, Actions.requestSend),
                        }).withKey(self.actions.draft_key) }),
                        cx.make(ui.IconButton{
                            .icon = .send,
                            .on_press = .of(self.actions, Actions.requestSend),
                        }),
                    },
                }) }),
            },
        });
    }

    /// "3 people: alice (you), bob, carol".
    fn people(self: *const Chat, cx: *ui.Context) []const u8 {
        const a = cx.ui.arena();
        var out: std.ArrayList(u8) = .empty;
        const count = self.members.len;
        out.print(a, "{d} {s}:", .{ count, if (count == 1) "person" else "people" }) catch return "";
        for (self.members, 0..) |name, i| {
            out.print(a, "{s} {s}{s}", .{ if (i == 0) "" else ",", name, if (i == 0) " (you)" else "" }) catch break;
        }
        return out.items;
    }
};

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");

fn overflows(node: *ui.Node) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.as(ui.Text)) |tx| if (std.mem.eql(u8, tx.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

fn up(n: *ui.Node, comptime T: type) ?*ui.Node {
    var at: ?*ui.Node = n;
    while (at) |x| : (at = x.parent) if (x.widget.is(T)) return x;
    return null;
}

fn click(u: *ui.Ui, n: *ui.Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
}

test "the lobby lists rooms to join and a way to start one" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const none: Chat = .{ .node = 1, .ads = &.{}, .room = null, .name = "kitchen-pi", .default_name = "kitchen-pi", .actions = &actions };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, none);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Start Room") != null);
    try testing.expect(findText(u.root.?, "Rooms on this network") != null);

    const ads = [_]net.Ad{
        .{ .room = 11, .name = protocol.Name.init("Lounge"), .members = 3 },
        .{ .room = 12, .name = protocol.Name.init("Workshop"), .members = 1 },
    };
    const some: Chat = .{ .node = 1, .ads = &ads, .room = null, .actions = &actions };
    for ([_][2]u32{ min_size, .{ 1280, 720 } }) |size| {
        u.frame(size[0], size[1], 1, some);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "3 people") != null);
    try testing.expect(findText(u.root.?, "1 person") != null);
    click(u, up(findText(u.root.?, "Workshop").?, ui.ListItem).?);
    try testing.expectEqual(@as(?u64, 12), actions.join);

    click(u, up(findText(u.root.?, "Start Room").?, ui.FilledButton).?);
    try testing.expect(actions.create);
}

fn findField(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.is(ui.TextField) and std.mem.eql(u8, n.state(ui.TextField.State).text(), text)) return n;
    for (n.children.items) |ch| if (findField(ch, text)) |f| return f;
    return null;
}

/// The settings button (the gear).
fn findSettings(n: *ui.Node) ?*ui.Node {
    if (n.widget.as(ui.IconButton)) |b| if (b.icon == .settings) return n;
    for (n.children.items) |ch| if (findSettings(ch)) |f| return f;
    return null;
}

test "the settings change the name" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var actions: Actions = .{};
    const chat: Chat = .{ .node = 1, .ads = &.{}, .room = null, .name = "Alice", .default_name = "kitchen-pi", .actions = &actions };
    u.frame(1280, 720, 0, chat);
    try testing.expect(findText(u.root.?, "You are Alice") != null);
    // A long name still fits.
    u.frame(min_size[0], min_size[1], 0, Chat{ .node = 1, .ads = &.{}, .room = null, .name = "W" ** protocol.max_name, .default_name = "kitchen-pi", .actions = &actions });
    try testing.expect(!overflows(u.root.?));
    u.frame(1280, 720, 0, chat);
    try testing.expect(findText(u.root.?, "Settings") == null);
    click(u, findSettings(u.root.?).?);
    try testing.expect(actions.open_settings);

    // Opened (main.zig does that), it has the name to change.
    actions.settings_open = true;
    for ([_][2]u32{ min_size, .{ 1280, 720 } }) |size| {
        u.frame(size[0], size[1], 1, chat);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Settings") != null);
    // Its field has the name (the lobby's, under it, is empty).
    try testing.expect(findField(u.root.?, "Alice") != null);
    click(u, up(findText(u.root.?, "Save").?, ui.FilledButton).?);
    try testing.expect(actions.save_settings);
    click(u, up(findText(u.root.?, "Cancel").?, ui.TextButton).?);
    try testing.expect(!actions.settings_open);
}

test "a room shows who is there and what was said, and sending asks to send" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var actions: Actions = .{};
    var room: net.Room = .{ .id = 1, .name = protocol.Name.init("Lounge"), .log = protocol.Log.init(testing.allocator), .connected = true };
    defer room.log.deinit();
    _ = try room.log.add(.{ .lamport = 1, .author = 2, .seq = 1, .name = "bob", .text = "Hello!" });
    _ = try room.log.add(.{ .lamport = 2, .author = 1, .seq = 1, .name = "alice", .text = "Hi Bob" });
    const members = [_][]const u8{ "alice", "bob" };
    const chat: Chat = .{ .node = 1, .ads = &.{}, .room = &room, .members = &members, .actions = &actions };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, chat);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Lounge") != null);
    try testing.expect(findText(u.root.?, "2 people: alice (you), bob") != null);
    try testing.expect(findText(u.root.?, "Hello!") != null);
    try testing.expect(findText(u.root.?, "Hi Bob") != null);
    // Its own are "You"; others' are by name.
    try testing.expect(findText(u.root.?, "You") != null);
    try testing.expect(findText(u.root.?, "bob") != null);

    click(u, up(findText(u.root.?, "Leave").?, ui.TonalButton).?);
    try testing.expect(actions.leave);

    // An empty room says so.
    var empty: net.Room = .{ .id = 2, .name = protocol.Name.init("Quiet"), .log = protocol.Log.init(testing.allocator), .connected = true };
    defer empty.log.deinit();
    u.frame(1280, 720, 1, Chat{ .node = 1, .ads = &.{}, .room = &empty, .members = members[0..1], .actions = &actions });
    try testing.expect(findText(u.root.?, "Nothing has been said yet.") != null);
    try testing.expect(findText(u.root.?, "1 person: alice (you)") != null);
}
