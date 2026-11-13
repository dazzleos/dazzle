//! Chat's window, as widgets. Outside a room it lists the rooms found on
//! the network, to join, with a field and a button to start one. In a room
//! it shows who is there, what has been said in order (scrolled to the
//! newest), and a field to say something in. Its settings (the gear, in
//! either) change the name others see.

const std = @import("std");
const kete = @import("kete");
const net = @import("net.zig");
const protocol = @import("protocol.zig");

pub const min_size = [2]u32{ 420, 360 };
pub const open_size = [2]u32{ 800, 640 };

/// What the window asked for, for the app to do (see main.zig), and what
/// is typed in its fields.
pub const Actions = struct {
    /// A new room's name, what is to be said, and (in the settings) the
    /// name others see: the fields' text, which the app reads and clears.
    room_name: kete.TextDocument,
    draft: kete.TextDocument,
    name: kete.TextDocument,
    create: bool = false,
    leave: bool = false,
    send: bool = false,
    /// A room to join (its id).
    join: ?u64 = null,
    dismiss: bool = false,
    /// The settings are shown, with the name being typed.
    settings_open: bool = false,
    open_settings: bool = false,
    save_settings: bool = false,

    pub fn init(gpa: std.mem.Allocator) Actions {
        return .{ .room_name = .{ .gpa = gpa }, .draft = .{ .gpa = gpa }, .name = .{ .gpa = gpa } };
    }

    pub fn deinit(a: *Actions) void {
        a.room_name.deinit();
        a.draft.deinit();
        a.name.deinit();
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

    pub fn build(self: *const Chat, cx: *kete.BuildContext) kete.Widget {
        const body = if (self.room) |room| self.inRoom(cx, room) else self.lobby(cx);
        return cx.make(kete.Dialog{
            .open = self.actions.settings_open,
            .icon = .settings,
            .title = "Settings",
            .description = cx.fmt("The name others see you as. Leave it empty to use this computer's name ({s}).", .{self.default_name}),
            .content = cx.make(kete.TextField{
                .doc = &self.actions.name,
                .placeholder = self.default_name,
                .width = std.math.inf(f32),
                .max_len = protocol.max_name,
                .autofocus = true,
                .on_submit = .of(self.actions, Actions.requestSaveSettings),
            }),
            .confirm_label = "Save",
            .on_confirm = .of(self.actions, Actions.requestSaveSettings),
            .dismiss_label = "Cancel",
            .on_dismiss = .of(self.actions, Actions.closeSettings),
            .child = body,
        });
    }

    fn settingsButton(self: *const Chat, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.IconButton{ .icon = .settings, .on_press = .of(self.actions, Actions.requestSettings) });
    }

    fn lobby(self: *const Chat, cx: *kete.BuildContext) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        const list = if (self.ads.len == 0)
            cx.make(kete.Align{ .child = cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Text{
                .text = "No rooms found. Start one and others on this network can join it.",
                .style = .{ .size = 16, .color = t.on_surface_variant },
                .text_align = .center,
            }) }) })
        else blk: {
            var rows: std.ArrayList(kete.Widget) = .empty;
            for (self.ads) |ad| {
                const press = a.create(JoinPress) catch break;
                press.* = .{ .actions = self.actions, .room = ad.room };
                rows.append(a, cx.make(kete.ListItem{
                    .leading_icon = .forum,
                    .headline = a.dupe(u8, ad.name.get()) catch "",
                    .supporting_text = if (ad.members == 1) "1 person" else cx.fmt("{d} people", .{ad.members}),
                    .on_press = .of(press, JoinPress.press),
                }).withKey(ad.room)) catch break;
            }
            break :blk cx.make(kete.ScrollView{ .child = cx.make(kete.Column{
                .cross_axis_alignment = .stretch,
                .spacing = 4,
                .children = rows.items,
            }) });
        };
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(kete.Expanded{ .child = cx.make(kete.Snackbar{
                .message = self.message,
                .on_dismiss = .of(self.actions, Actions.requestDismiss),
                .child = cx.make(kete.Align{ .height_factor = 1, .child = cx.make(kete.ConstrainedBox{
                    .constraints = .{ .max_w = 560 },
                    .child = cx.make(kete.Padding{ .padding = .symmetric(12, 8), .child = cx.make(kete.Column{
                        .cross_axis_alignment = .stretch,
                        .spacing = 12,
                        .children = &.{
                            cx.make(kete.Row{ .spacing = 8, .cross_axis_alignment = .center, .children = &.{
                                cx.make(kete.Icon{ .icon = .person, .color = t.on_surface_variant }),
                                cx.make(kete.Expanded{ .child = cx.make(kete.Text{
                                    .text = cx.fmt("You are {s}", .{self.name}),
                                    .style = .{ .size = 16, .color = t.on_surface },
                                    .wrap = false,
                                    .ellipsis = true,
                                }) }),
                                self.settingsButton(cx),
                            } }),
                            cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                                cx.make(kete.Expanded{ .child = cx.make(kete.TextField{
                                    .doc = &self.actions.room_name,
                                    .placeholder = "Name for a new room",
                                    .width = std.math.inf(f32),
                                    .max_len = protocol.max_name,
                                    .autofocus = true,
                                    .on_submit = .of(self.actions, Actions.requestCreate),
                                }) }),
                                cx.make(kete.FilledButton{
                                    .label = "Start Room",
                                    .icon = .add,
                                    .on_press = .of(self.actions, Actions.requestCreate),
                                }),
                            } }),
                            cx.make(kete.Padding{ .padding = .{ .top = 4 }, .child = cx.make(kete.Text{
                                .text = "Rooms on this network",
                                .style = .{ .size = 16, .color = t.on_surface_variant },
                                .wrap = false,
                            }) }),
                            cx.make(kete.HorizontalDivider{}),
                            cx.make(kete.Expanded{ .child = list }),
                        },
                    }) }),
                }) }),
            }) }),
        } });
    }

    fn inRoom(self: *const Chat, cx: *kete.BuildContext, room: *const net.Room) kete.Widget {
        const t = cx.theme();
        const a = cx.arena;
        const messages = room.log.items.items;

        var rows: std.ArrayList(kete.Widget) = .empty;
        for (messages, 0..) |m, i| {
            const mine = m.author == self.node;
            rows.append(a, cx.make(kete.Padding{ .padding = .symmetric(0, 5), .child = cx.make(kete.Column{
                .cross_axis_alignment = .stretch,
                .children = &.{
                    cx.make(kete.Text{
                        .text = if (mine) "You" else m.name,
                        .style = .{ .size = 14, .color = if (mine) t.primary else t.on_surface_variant },
                        .wrap = false,
                        .ellipsis = true,
                    }),
                    cx.make(kete.Text{ .text = m.text, .style = .{ .size = 18, .color = t.on_surface } }),
                },
            }) }).withKey(i + 1)) catch break;
        }
        if (messages.len == 0) rows.append(a, cx.make(kete.Padding{ .padding = .all(16), .child = cx.make(kete.Text{
            .text = "Nothing has been said yet.",
            .style = .{ .size = 16, .color = t.on_surface_variant },
            .text_align = .center,
        }) })) catch {};

        return cx.make(kete.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(kete.Padding{ .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 }, .child = cx.make(kete.Row{
                    .spacing = 12,
                    .cross_axis_alignment = .center,
                    .children = &.{
                        cx.make(kete.TonalButton{
                            .label = "Leave",
                            .icon = .logout,
                            .on_press = .of(self.actions, Actions.requestLeave),
                        }),
                        cx.make(kete.Icon{ .icon = .group, .color = t.on_surface_variant }),
                        cx.make(kete.Expanded{ .child = cx.make(kete.Text{
                            .text = self.people(cx),
                            .style = .{ .size = 15, .color = t.on_surface_variant },
                            .wrap = false,
                            .ellipsis = true,
                        }) }),
                        self.settingsButton(cx),
                    },
                }) }),
                cx.make(kete.HorizontalDivider{}),
                cx.make(kete.Expanded{
                    .child = cx.make(kete.Snackbar{
                        .message = self.message,
                        .on_dismiss = .of(self.actions, Actions.requestDismiss),
                        .child = cx.make(kete.ScrollView{
                            // Newest in view as they come.
                            .reveal = if (messages.len > 0) messages.len else null,
                            .child = cx.make(kete.Padding{ .padding = .symmetric(16, 8), .child = cx.make(kete.Column{
                                .cross_axis_alignment = .stretch,
                                .fill = false,
                                .children = rows.items,
                            }) }),
                        }),
                    }),
                }),
                cx.make(kete.Padding{ .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 12 }, .child = cx.make(kete.Row{
                    .spacing = 8,
                    .cross_axis_alignment = .center,
                    .children = &.{
                        cx.make(kete.Expanded{ .child = cx.make(kete.TextField{
                            .doc = &self.actions.draft,
                            .placeholder = "Say something",
                            .width = std.math.inf(f32),
                            .max_len = protocol.max_text,
                            .autofocus = true,
                            .on_submit = .of(self.actions, Actions.requestSend),
                        }) }),
                        cx.make(kete.IconButton{
                            .icon = .send,
                            .on_press = .of(self.actions, Actions.requestSend),
                        }),
                    },
                }) }),
            },
        });
    }

    /// "3 people: alice (you), bob, carol".
    fn people(self: *const Chat, cx: *kete.BuildContext) []const u8 {
        const a = cx.arena;
        var out: std.ArrayList(u8) = .empty;
        const count = self.members.len;
        out.print(a, "{d} {s}:", .{ count, if (count == 1) "person" else "people" }) catch return "";
        for (self.members, 0..) |name, i| {
            out.print(a, "{s} {s}{s}", .{ if (i == 0) "" else ",", name, if (i == 0) " (you)" else "" }) catch break;
        }
        return out.items;
    }
};

/// The window's title: the room's name, in a room.
pub fn windowTitle(room: ?*const net.Room) []const u8 {
    return if (room) |r| r.name.get() else "Chat";
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;
const font = kete.font;

fn overflows(node: *kete.WidgetNode) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *kete.WidgetNode, text: []const u8) ?*kete.WidgetNode {
    if (n.widget.as(kete.Text)) |tx| if (std.mem.eql(u8, tx.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

fn up(n: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
    var at: ?*kete.WidgetNode = n;
    while (at) |x| : (at = x.parent) if (x.widget.is(T)) return x;
    return null;
}

fn click(u: *kete.ui.WindowUi, n: *kete.WidgetNode) void {
    const at = n.position();
    const p: kete.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
}

test "the lobby lists rooms to join and a way to start one" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .init(testing.allocator);
    defer actions.deinit();
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
    click(u, up(findText(u.root.?, "Workshop").?, kete.ListItem).?);
    try testing.expectEqual(@as(?u64, 12), actions.join);

    click(u, up(findText(u.root.?, "Start Room").?, kete.FilledButton).?);
    try testing.expect(actions.create);
}

fn findField(n: *kete.WidgetNode, text: []const u8) ?*kete.WidgetNode {
    if (n.widget.is(kete.TextField) and std.mem.eql(u8, n.state(kete.TextField.State).text(), text)) return n;
    for (n.children.items) |ch| if (findField(ch, text)) |f| return f;
    return null;
}

/// The settings button (the gear).
fn findSettings(n: *kete.WidgetNode) ?*kete.WidgetNode {
    if (n.widget.as(kete.IconButton)) |b| if (b.icon == .settings) return n;
    for (n.children.items) |ch| if (findSettings(ch)) |f| return f;
    return null;
}

test "the settings change the name" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .init(testing.allocator);
    defer actions.deinit();
    const chat: Chat = .{ .node = 1, .ads = &.{}, .room = null, .name = "Alice", .default_name = "kitchen-pi", .actions = &actions };
    u.frame(1280, 720, 0, chat);
    try testing.expect(findText(u.root.?, "You are Alice") != null);
    // A long name still fits.
    u.frame(min_size[0], min_size[1], 0, Chat{ .node = 1, .ads = &.{}, .room = null, .name = &@as([protocol.max_name]u8, @splat('W')), .default_name = "kitchen-pi", .actions = &actions });
    try testing.expect(!overflows(u.root.?));
    u.frame(1280, 720, 0, chat);
    try testing.expect(findText(u.root.?, "Settings") == null);
    click(u, findSettings(u.root.?).?);
    try testing.expect(actions.open_settings);

    // Opened (main.zig does that), it has the name to change.
    actions.settings_open = true;
    actions.name.setText("Alice");
    for ([_][2]u32{ min_size, .{ 1280, 720 } }) |size| {
        u.frame(size[0], size[1], 1, chat);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Settings") != null);
    // Its field has the name (the lobby's, under it, is empty).
    try testing.expect(findField(u.root.?, "Alice") != null);
    click(u, up(findText(u.root.?, "Save").?, kete.FilledButton).?);
    try testing.expect(actions.save_settings);
    click(u, up(findText(u.root.?, "Cancel").?, kete.TextButton).?);
    try testing.expect(!actions.settings_open);
}

test "a room shows who is there and what was said, and sending asks to send" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var actions: Actions = .init(testing.allocator);
    defer actions.deinit();
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
    try testing.expectEqualStrings("Lounge", windowTitle(&room));
    try testing.expectEqualStrings("Chat", windowTitle(null));
    try testing.expect(findText(u.root.?, "2 people: alice (you), bob") != null);
    try testing.expect(findText(u.root.?, "Hello!") != null);
    try testing.expect(findText(u.root.?, "Hi Bob") != null);
    // Its own are "You"; others' are by name.
    try testing.expect(findText(u.root.?, "You") != null);
    try testing.expect(findText(u.root.?, "bob") != null);

    // What is to be said is the draft's; once sent, the app empties it.
    actions.draft.setText("See you");
    u.frame(1280, 720, 0, chat);
    try testing.expect(findField(u.root.?, "See you") != null);
    actions.draft.setText("");
    u.frame(1280, 720, 0, chat);
    try testing.expect(findField(u.root.?, "See you") == null);

    click(u, up(findText(u.root.?, "Leave").?, kete.TonalButton).?);
    try testing.expect(actions.leave);

    // An empty room says so.
    var empty: net.Room = .{ .id = 2, .name = protocol.Name.init("Quiet"), .log = protocol.Log.init(testing.allocator), .connected = true };
    defer empty.log.deinit();
    u.frame(1280, 720, 1, Chat{ .node = 1, .ads = &.{}, .room = &empty, .members = members[0..1], .actions = &actions });
    try testing.expect(findText(u.root.?, "Nothing has been said yet.") != null);
    try testing.expect(findText(u.root.?, "1 person: alice (you)") != null);
}
