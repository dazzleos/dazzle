//! The widget showcase's window: a `NavigationRail` sidebar beside pages
//! demonstrating every Material 3 widget in the `ui` toolkit.

const std = @import("std");
const gfx = @import("gfx");
const ui = @import("ui");

pub const min_size = [2]u32{ 800, 480 };
pub const open_size = [2]u32{ 1120, 740 };

pub const initial_notes =
    \\Material 3 Widget Showcase
    \\Edit multi-line text here with selection, copy and paste.
;

pub const Page = enum(usize) {
    actions = 0,
    inputs = 1,
    containers = 2,
    feedback = 3,
};

pub const SpeedPreset = enum {
    slow,
    normal,
    fast,
    turbo,
};

pub const Showcase = struct {
    doc: ?*ui.TextDocument = null,

    pub const State = struct {
        page: Page = .actions,
        sub_tab: usize = 0,
        extended_rail: bool = true,
        light_theme: bool = false,

        // Buttons & Chips state.
        button_clicks: u32 = 0,
        pill_index: usize = 0,
        fav_selected: bool = true,
        mute_selected: bool = false,
        lock_selected: bool = false,
        chip_wifi: bool = true,
        chip_gpio: bool = false,
        chip_usb: bool = true,
        tag_visible: [3]bool = .{ true, true, true },

        // Inputs & Sliders state.
        continuous_val: f32 = 0.65,
        discrete_val: f32 = 60,
        animate_progress: bool = false,
        dropdown_idx: usize = 1,
        preset: SpeedPreset = .normal,
        check_a: bool = true,
        check_b: bool = false,
        switch_notifications: bool = true,
        radio_choice: u8 = 0,
        text_buf: [64]u8 = undefined,
        text_len: usize = 0,

        // Containers & Lists state.
        selected_card: usize = 0,
        selected_list_item: usize = 0,
        badge_count: u32 = 3,

        // Dialogs & Feedback state.
        confirm_dialog_open: bool = false,
        confirmed_count: u32 = 0,
        snackbar_msg: []const u8 = "Welcome to the Dazzle Material 3 widget showcase",
        snackbar_undo_count: u32 = 0,

        fn selectPage(s: *State, idx: usize) void {
            if (idx <= @intFromEnum(Page.feedback)) s.page = @enumFromInt(idx);
        }

        fn selectTab(s: *State, idx: usize) void {
            s.sub_tab = idx;
        }

        fn setExtendedRail(s: *State, v: bool) void {
            s.extended_rail = v;
        }

        fn setLightTheme(s: *State, v: bool) void {
            s.light_theme = v;
        }

        fn addClick(s: *State) void {
            s.button_clicks += 1;
        }

        fn setPill0(s: *State) void {
            s.pill_index = 0;
        }
        fn setPill1(s: *State) void {
            s.pill_index = 1;
        }
        fn setPill2(s: *State) void {
            s.pill_index = 2;
        }

        fn toggleFav(s: *State) void {
            s.fav_selected = !s.fav_selected;
        }
        fn toggleMute(s: *State) void {
            s.mute_selected = !s.mute_selected;
        }
        fn toggleLock(s: *State) void {
            s.lock_selected = !s.lock_selected;
        }

        fn toggleChipWifi(s: *State) void {
            s.chip_wifi = !s.chip_wifi;
        }
        fn toggleChipGpio(s: *State) void {
            s.chip_gpio = !s.chip_gpio;
        }
        fn toggleChipUsb(s: *State) void {
            s.chip_usb = !s.chip_usb;
        }
        fn removeTag0(s: *State) void {
            s.tag_visible[0] = false;
        }
        fn removeTag1(s: *State) void {
            s.tag_visible[1] = false;
        }
        fn removeTag2(s: *State) void {
            s.tag_visible[2] = false;
        }
        fn resetTags(s: *State) void {
            s.tag_visible = .{ true, true, true };
        }

        fn setContinuous(s: *State, v: f32) void {
            s.continuous_val = v;
        }
        fn setDiscrete(s: *State, v: f32) void {
            s.discrete_val = v;
        }
        fn setAnimateProgress(s: *State, v: bool) void {
            s.animate_progress = v;
        }
        fn setDropdown(s: *State, idx: usize) void {
            s.dropdown_idx = idx;
        }
        fn setPreset(s: *State, p: SpeedPreset) void {
            s.preset = p;
        }
        fn setCheckA(s: *State, v: bool) void {
            s.check_a = v;
        }
        fn setCheckB(s: *State, v: bool) void {
            s.check_b = v;
        }
        fn setNotifications(s: *State, v: bool) void {
            s.switch_notifications = v;
        }
        fn setRadio(s: *State, v: u8) void {
            s.radio_choice = v;
        }
        fn setText(s: *State, txt: []const u8) void {
            const n = @min(txt.len, s.text_buf.len);
            @memcpy(s.text_buf[0..n], txt[0..n]);
            s.text_len = n;
        }

        fn selectCard0(s: *State) void {
            s.selected_card = 0;
        }
        fn selectCard1(s: *State) void {
            s.selected_card = 1;
        }
        fn selectCard2(s: *State) void {
            s.selected_card = 2;
        }
        fn selectList0(s: *State) void {
            s.selected_list_item = 0;
        }
        fn selectList1(s: *State) void {
            s.selected_list_item = 1;
        }
        fn selectList2(s: *State) void {
            s.selected_list_item = 2;
        }
        fn addBadge(s: *State) void {
            s.badge_count +|= 1;
        }
        fn clearBadge(s: *State) void {
            s.badge_count = 0;
        }

        fn openDialog(s: *State) void {
            s.confirm_dialog_open = true;
        }
        fn closeDialog(s: *State) void {
            s.confirm_dialog_open = false;
        }
        fn confirmDialog(s: *State) void {
            s.confirm_dialog_open = false;
            s.confirmed_count += 1;
            s.snackbar_msg = "Dialog action confirmed";
        }
        fn showSavedSnackbar(s: *State) void {
            s.snackbar_msg = "Configuration saved to disk";
        }
        fn showNetworkSnackbar(s: *State) void {
            s.snackbar_msg = "Connected to Wi-Fi network";
        }
        fn dismissSnackbar(s: *State) void {
            s.snackbar_msg = "";
        }
        fn undoSnackbar(s: *State) void {
            s.snackbar_undo_count += 1;
            s.snackbar_msg = "";
        }
    };

    pub fn build(self: *const Showcase, cx: *ui.Context, state: *State) ui.Widget {
        cx.ui.theme = if (state.light_theme) .light else .dark;
        const t = cx.theme();

        const rail_items = [_]ui.NavigationRail.Item{
            .{ .label = "Actions", .icon = .apps },
            .{ .label = "Inputs", .icon = .settings_input_component },
            .{ .label = "Containers", .icon = .view_list, .badge = if (state.badge_count > 0) state.badge_count else null },
            .{ .label = "Feedback", .icon = .info },
        };

        const header = cx.make(ui.Padding{
            .padding = .symmetric(20, 10),
            .child = cx.make(ui.Row{
                .cross_axis_alignment = .center,
                .spacing = 12,
                .children = &.{
                    cx.make(ui.Expanded{
                        .child = cx.make(ui.Text{
                            .text = "Material 3 Showcase",
                            .style = .{ .size = 20, .color = t.on_surface },
                            .wrap = false,
                            .ellipsis = true,
                        }),
                    }),
                    cx.make(ui.Switch{
                        .value = state.extended_rail,
                        .on_changed = .of(state, State.setExtendedRail),
                        .label = "Wide rail",
                    }),
                    cx.make(ui.Switch{
                        .value = state.light_theme,
                        .on_changed = .of(state, State.setLightTheme),
                        .label = "Light",
                    }),
                },
            }),
        });

        const page_content = switch (state.page) {
            .actions => buildActionsPage(cx, state),
            .inputs => buildInputsPage(cx, state, self.doc),
            .containers => buildContainersPage(cx, state),
            .feedback => buildFeedbackPage(cx, state),
        };

        const body = cx.make(ui.Row{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(ui.NavigationRail{
                    .items = &rail_items,
                    .selected = @intFromEnum(state.page),
                    .on_select = .of(state, State.selectPage),
                    .extended = state.extended_rail,
                }),
                cx.make(ui.Divider{ .axis = .vertical }),
                cx.make(ui.Expanded{
                    .child = cx.make(ui.Column{
                        .cross_axis_alignment = .stretch,
                        .children = &.{
                            header,
                            cx.make(ui.Divider{}),
                            cx.make(ui.Expanded{
                                .child = cx.make(ui.ScrollView{
                                    .child = cx.make(ui.Padding{
                                        .padding = .all(24),
                                        .child = page_content,
                                    }),
                                }),
                            }),
                        },
                    }),
                }),
            },
        });

        const with_snackbar = cx.make(ui.Snackbar{
            .message = state.snackbar_msg,
            .action_label = "Undo",
            .on_action = .of(state, State.undoSnackbar),
            .on_dismiss = .of(state, State.dismissSnackbar),
            .child = body,
        });

        const with_dialog = cx.make(ui.Dialog{
            .open = state.confirm_dialog_open,
            .icon = .info,
            .title = "Apply configuration?",
            .description = "This modal dialog demonstrates Material 3 scrims, surface elevation, headline typography, and primary/secondary button emphasis.",
            .dismiss_label = "Cancel",
            .on_dismiss = .of(state, State.closeDialog),
            .confirm_label = "Confirm",
            .on_confirm = .of(state, State.confirmDialog),
            .child = with_snackbar,
        });

        return cx.make(ui.Decorated{
            .color = t.surface,
            .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .children = &.{
                    cx.make(ui.TitleBar{ .title = "Widget Showcase" }),
                    cx.make(ui.Expanded{ .child = with_dialog }),
                },
            }),
        });
    }
};

fn sectionHeading(cx: *ui.Context, title: []const u8, subtitle: []const u8) ui.Widget {
    const t = cx.theme();
    return cx.make(ui.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .start,
        .spacing = 4,
        .children = &.{
            cx.make(ui.Text{ .text = title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false }),
            cx.make(ui.Text{ .text = subtitle, .style = .{ .size = 13, .color = t.on_surface_variant } }),
        },
    });
}

fn buildActionsPage(cx: *ui.Context, state: *Showcase.State) ui.Widget {
    const t = cx.theme();

    var tag_widgets: [4]ui.Widget = undefined;
    var tag_count: usize = 0;
    const tag_labels = [3][]const u8{ "raspberry-pi", "wayland", "vc4-gpu" };
    const tag_removes = [3]ui.Callback{
        .of(state, Showcase.State.removeTag0),
        .of(state, Showcase.State.removeTag1),
        .of(state, Showcase.State.removeTag2),
    };
    for (tag_labels, tag_removes, state.tag_visible) |lbl, rem, vis| {
        if (vis) {
            tag_widgets[tag_count] = cx.make(ui.Chip{
                .label = lbl,
                .on_press = .of(state, Showcase.State.addClick),
                .on_remove = rem,
            });
            tag_count += 1;
        }
    }
    tag_widgets[tag_count] = cx.make(ui.TextButton{
        .label = "Reset tags",
        .icon = .refresh,
        .on_press = .of(state, Showcase.State.resetTags),
    });
    tag_count += 1;

    return cx.make(ui.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 18,
        .children = &.{
            sectionHeading(cx, "Button Emphasis Variants", cx.fmt("Filled, tonal, outlined and text buttons  ·  pressed {d} times", .{state.button_clicks})),
            cx.make(ui.Row{
                .spacing = 10,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.FilledButton{ .label = "Filled", .icon = .add, .on_press = .of(state, Showcase.State.addClick) }),
                    cx.make(ui.TonalButton{ .label = "Tonal", .icon = .edit, .on_press = .of(state, Showcase.State.addClick) }),
                    cx.make(ui.OutlinedButton{ .label = "Outlined", .icon = .download, .on_press = .of(state, Showcase.State.addClick) }),
                    cx.make(ui.TextButton{ .label = "Text", .on_press = .of(state, Showcase.State.addClick) }),
                },
            }),
            cx.make(ui.Row{
                .spacing = 10,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.FilledButton{ .label = "Disabled" }),
                    cx.make(ui.OutlinedButton{ .label = "Disabled Outlined" }),
                },
            }),
            cx.make(ui.Divider{}),
            sectionHeading(cx, "Segmented PillBar", "Single-select segmented button group"),
            cx.make(ui.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.PillBar{ .children = &.{
                        cx.make(ui.PillButton{ .label = "Day", .selected = state.pill_index == 0, .first = true, .on_press = .of(state, Showcase.State.setPill0) }),
                        cx.make(ui.PillButton{ .label = "Week", .selected = state.pill_index == 1, .on_press = .of(state, Showcase.State.setPill1) }),
                        cx.make(ui.PillButton{ .label = "Month", .selected = state.pill_index == 2, .last = true, .on_press = .of(state, Showcase.State.setPill2) }),
                    } }),
                    cx.make(ui.Text{
                        .text = cx.fmt("Selected segment: {d}", .{state.pill_index}),
                        .style = .{ .size = 14, .color = t.on_surface_variant },
                        .wrap = false,
                    }),
                },
            }),
            cx.make(ui.Divider{}),
            sectionHeading(cx, "Icon Buttons & Tooltips", "Standard, filled, tonal and outlined icon buttons wrapped in hover tooltips"),
            cx.make(ui.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.Tooltip{
                        .text = "Standard icon button",
                        .child = cx.make(ui.IconButton{
                            .icon = .settings,
                            .variant = .standard,
                            .selected = state.fav_selected,
                            .on_press = .of(state, Showcase.State.toggleFav),
                        }),
                    }),
                    cx.make(ui.Tooltip{
                        .text = "Filled icon button",
                        .child = cx.make(ui.IconButton{
                            .icon = .play_arrow,
                            .variant = .filled,
                            .on_press = .of(state, Showcase.State.addClick),
                        }),
                    }),
                    cx.make(ui.Tooltip{
                        .text = "Tonal toggle button",
                        .child = cx.make(ui.IconButton{
                            .icon = .wifi,
                            .variant = .tonal,
                            .selected = state.mute_selected,
                            .on_press = .of(state, Showcase.State.toggleMute),
                        }),
                    }),
                    cx.make(ui.Tooltip{
                        .text = "Outlined toggle button",
                        .child = cx.make(ui.IconButton{
                            .icon = .lock,
                            .variant = .outlined,
                            .selected = state.lock_selected,
                            .on_press = .of(state, Showcase.State.toggleLock),
                        }),
                    }),
                    cx.make(ui.Tooltip{
                        .text = "Disabled icon button",
                        .child = cx.make(ui.IconButton{
                            .icon = .delete,
                            .variant = .outlined,
                        }),
                    }),
                },
            }),
            cx.make(ui.Divider{}),
            sectionHeading(cx, "Chips", "Filter chips with selection checkmarks and removable input chips"),
            cx.make(ui.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.Chip{ .label = "Wi-Fi", .icon = .wifi, .selected = state.chip_wifi, .on_press = .of(state, Showcase.State.toggleChipWifi) }),
                    cx.make(ui.Chip{ .label = "GPIO", .icon = .developer_board, .selected = state.chip_gpio, .on_press = .of(state, Showcase.State.toggleChipGpio) }),
                    cx.make(ui.Chip{ .label = "USB", .icon = .usb, .selected = state.chip_usb, .on_press = .of(state, Showcase.State.toggleChipUsb) }),
                },
            }),
            cx.make(ui.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = tag_widgets[0..tag_count],
            }),
        },
    });
}

fn buildInputsPage(cx: *ui.Context, state: *Showcase.State, doc: ?*ui.TextDocument) ui.Widget {
    const t = cx.theme();
    const dropdown_options = [_][]const u8{ "1080p Full HD (60 Hz)", "720p HD (60 Hz)", "480p SD (60 Hz)" };
    const preset_options = [_]ui.Select(SpeedPreset).Option{
        .{ .value = .slow, .label = "Slow (1 Hz)" },
        .{ .value = .normal, .label = "Normal (10 Hz)" },
        .{ .value = .fast, .label = "Fast (100 Hz)" },
        .{ .value = .turbo, .label = "Turbo (1 kHz)" },
    };

    var progress_row: [3]ui.Widget = undefined;
    var prog_count: usize = 0;
    progress_row[prog_count] = cx.make(ui.Switch{
        .value = state.animate_progress,
        .on_changed = .of(state, Showcase.State.setAnimateProgress),
        .label = "Animate indeterminate",
    });
    prog_count += 1;
    if (state.animate_progress) {
        progress_row[prog_count] = cx.make(ui.Expanded{ .child = cx.make(ui.ProgressBar{ .value = null }) });
        prog_count += 1;
        progress_row[prog_count] = cx.make(ui.Spinner{ .size = 28 });
        prog_count += 1;
    }

    return cx.make(ui.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 18,
        .children = &.{
            sectionHeading(cx, "Sliders & Progress Indicators", "Continuous and discrete sliders driving a determinate linear ProgressBar"),
            cx.make(ui.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.SizedBox{ .width = 140, .child = cx.make(ui.Text{ .text = cx.fmt("Continuous: {d:.0}%", .{state.continuous_val * 100}), .style = .{ .size = 14, .color = t.on_surface }, .wrap = false }) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Slider{
                        .value = state.continuous_val,
                        .on_changed = .of(state, Showcase.State.setContinuous),
                    }) }),
                },
            }),
            cx.make(ui.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.SizedBox{ .width = 140, .child = cx.make(ui.Text{ .text = cx.fmt("Discrete (5 steps): {d:.0}", .{state.discrete_val}), .style = .{ .size = 14, .color = t.on_surface }, .wrap = false }) }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.Slider{
                        .value = state.discrete_val,
                        .min = 0,
                        .max = 100,
                        .divisions = 5,
                        .on_changed = .of(state, Showcase.State.setDiscrete),
                    }) }),
                },
            }),
            cx.make(ui.ProgressBar{ .value = state.continuous_val, .height = 8 }),
            cx.make(ui.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = progress_row[0..prog_count],
            }),
            cx.make(ui.Divider{}),
            sectionHeading(cx, "Dropdown Menus & Typed Selects", "Popup menus anchored below outlined selector fields"),
            cx.make(ui.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.DropdownMenu{
                        .options = &dropdown_options,
                        .selected = state.dropdown_idx,
                        .on_selected = .of(state, Showcase.State.setDropdown),
                        .icon = .videocam,
                        .width = 220,
                    }),
                    cx.make(ui.Select(SpeedPreset){
                        .options = &preset_options,
                        .value = state.preset,
                        .on_changed = .of(state, Showcase.State.setPreset),
                        .icon = .speed,
                        .width = 190,
                    }),
                },
            }),
            cx.make(ui.Divider{}),
            sectionHeading(cx, "Selection Controls", "Checkboxes, switches and radio buttons"),
            cx.make(ui.Row{
                .spacing = 20,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.Checkbox{ .value = state.check_a, .on_changed = .of(state, Showcase.State.setCheckA), .label = "Enable logging" }),
                    cx.make(ui.Checkbox{ .value = state.check_b, .on_changed = .of(state, Showcase.State.setCheckB), .label = "Auto-scroll" }),
                    cx.make(ui.Switch{ .value = state.switch_notifications, .on_changed = .of(state, Showcase.State.setNotifications), .label = "Alerts" }),
                },
            }),
            cx.make(ui.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.Radio(u8){ .value = 0, .group_value = state.radio_choice, .on_changed = .of(state, Showcase.State.setRadio), .label = "Channel A" }),
                    cx.make(ui.Radio(u8){ .value = 1, .group_value = state.radio_choice, .on_changed = .of(state, Showcase.State.setRadio), .label = "Channel B" }),
                    cx.make(ui.Radio(u8){ .value = 2, .group_value = state.radio_choice, .on_changed = .of(state, Showcase.State.setRadio), .label = "Channel C" }),
                },
            }),
            cx.make(ui.Divider{}),
            sectionHeading(cx, "TextField & TextArea", "Single-line and multi-line editable text controls"),
            cx.make(ui.TextField{
                .placeholder = "Type a hostname or filter...",
                .initial = state.text_buf[0..state.text_len],
                .on_changed = .of(state, Showcase.State.setText),
            }),
            if (doc) |d|
                cx.make(ui.SizedBox{
                    .height = 96,
                    .child = cx.make(ui.Decorated{
                        .color = t.surface_container,
                        .border = .{ .width = 1, .color = t.outline_variant },
                        .radius = .all(8),
                        .child = cx.make(ui.TextArea{ .doc = d }),
                    }),
                })
            else
                cx.make(ui.Empty{}),
        },
    });
}

fn buildContainersPage(cx: *ui.Context, state: *Showcase.State) ui.Widget {
    const t = cx.theme();
    const tabs = [_]ui.Tab{
        .{ .label = "Cards & Badges", .icon = .grid_view },
        .{ .label = "List Items", .icon = .view_list, .badge = if (state.badge_count > 0) state.badge_count else null },
    };

    const tab_body = if (state.sub_tab == 0)
        cx.make(ui.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .spacing = 16,
            .children = &.{
                sectionHeading(cx, "Cards", "Filled, elevated and outlined Material 3 surface cards (click to select)"),
                cx.make(ui.Row{
                    .spacing = 16,
                    .cross_axis_alignment = .start,
                    .children = &.{
                        cx.make(ui.Expanded{ .child = cx.make(ui.Card{
                            .variant = .filled,
                            .selected = state.selected_card == 0,
                            .on_press = .of(state, Showcase.State.selectCard0),
                            .child = cx.make(ui.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(ui.Text{ .text = "Filled Card", .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }),
                                    cx.make(ui.Text{ .text = "High-contrast surface container for featured items.", .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }) }),
                        cx.make(ui.Expanded{ .child = cx.make(ui.Card{
                            .variant = .elevated,
                            .selected = state.selected_card == 1,
                            .on_press = .of(state, Showcase.State.selectCard1),
                            .child = cx.make(ui.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(ui.Text{ .text = "Elevated Card", .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }),
                                    cx.make(ui.Text{ .text = "Tonal surface container separating content from background.", .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }) }),
                        cx.make(ui.Expanded{ .child = cx.make(ui.Card{
                            .variant = .outlined,
                            .selected = state.selected_card == 2,
                            .on_press = .of(state, Showcase.State.selectCard2),
                            .child = cx.make(ui.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(ui.Text{ .text = "Outlined Card", .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }),
                                    cx.make(ui.Text{ .text = "Clean outline border on the base surface colour.", .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }) }),
                    },
                }),
                cx.make(ui.Divider{}),
                sectionHeading(cx, "Badges", "Status dots, notification counts, 99+ overflow and custom labels"),
                cx.make(ui.Row{
                    .spacing = 24,
                    .main_axis_size = .min,
                    .cross_axis_alignment = .center,
                    .children = &.{
                        cx.make(ui.Badge{ .child = cx.make(ui.Icon{ .icon = .wifi, .size = 28 }) }),
                        cx.make(ui.Badge{ .count = state.badge_count, .show = state.badge_count > 0, .child = cx.make(ui.Icon{ .icon = .folder, .size = 28 }) }),
                        cx.make(ui.Badge{ .count = 128, .child = cx.make(ui.Icon{ .icon = . article, .size = 28 }) }),
                        cx.make(ui.Badge{ .label = "NEW" }),
                        cx.make(ui.OutlinedButton{ .label = "Add badge", .icon = .add, .on_press = .of(state, Showcase.State.addBadge) }),
                        cx.make(ui.TextButton{ .label = "Clear", .on_press = .of(state, Showcase.State.clearBadge) }),
                    },
                }),
            },
        })
    else
        cx.make(ui.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .spacing = 12,
            .children = &.{
                sectionHeading(cx, "List Items & Dividers", "One-line and two-line list rows inside an outlined Card"),
                cx.make(ui.Card{
                    .variant = .outlined,
                    .padding = .all(4),
                    .child = cx.make(ui.Column{
                        .main_axis_size = .min,
                        .cross_axis_alignment = .stretch,
                        .children = &.{
                            cx.make(ui.ListItem{
                                .headline = "Wi-Fi Network",
                                .supporting_text = "Connected to Canonical-5G (192.168.1.42/24)",
                                .leading_icon = .wifi,
                                .trailing_text = "5 GHz",
                                .trailing_icon = .chevron_right,
                                .selected = state.selected_list_item == 0,
                                .on_press = .of(state, Showcase.State.selectList0),
                            }),
                            cx.make(ui.Divider{ .inset = 16 }),
                            cx.make(ui.ListItem{
                                .headline = "GPIO Header",
                                .supporting_text = "40-pin Raspberry Pi header  ·  I2C1 and SPI0 enabled",
                                .leading_icon = .developer_board,
                                .trailing_icon = .chevron_right,
                                .selected = state.selected_list_item == 1,
                                .on_press = .of(state, Showcase.State.selectList1),
                            }),
                            cx.make(ui.Divider{ .inset = 16 }),
                            cx.make(ui.ListItem{
                                .headline = "USB Storage Drive",
                                .supporting_text = "14.2 GB free of 16.0 GB",
                                .leading_icon = .usb,
                                .trailing = cx.make(ui.Badge{ .label = "Mounted", .color = t.primary }),
                                .selected = state.selected_list_item == 2,
                                .on_press = .of(state, Showcase.State.selectList2),
                            }),
                        },
                    }),
                }),
            },
        });

    return cx.make(ui.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 20,
        .children = &.{
            cx.make(ui.TabBar{
                .tabs = &tabs,
                .selected = state.sub_tab,
                .on_select = .of(state, Showcase.State.selectTab),
            }),
            tab_body,
        },
    });
}

fn buildFeedbackPage(cx: *ui.Context, state: *Showcase.State) ui.Widget {
    return cx.make(ui.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 20,
        .children = &.{
            sectionHeading(
                cx,
                "Modal Dialog",
                cx.fmt("Opens a centered Dialog over a dimmed backdrop  ·  confirmed {d} times", .{state.confirmed_count}),
            ),
            cx.make(ui.Row{
                .spacing = 12,
                .main_axis_size = .min,
                .children = &.{
                    cx.make(ui.FilledButton{
                        .label = "Open Dialog",
                        .icon = .info,
                        .on_press = .of(state, Showcase.State.openDialog),
                    }),
                },
            }),
            cx.make(ui.Divider{}),
            sectionHeading(
                cx,
                "Snackbar",
                cx.fmt("Bottom notification bar with action and dismiss buttons  ·  undo pressed {d} times", .{state.snackbar_undo_count}),
            ),
            cx.make(ui.Row{
                .spacing = 12,
                .main_axis_size = .min,
                .children = &.{
                    cx.make(ui.TonalButton{
                        .label = "Show Saved Snackbar",
                        .icon = .save,
                        .on_press = .of(state, Showcase.State.showSavedSnackbar),
                    }),
                    cx.make(ui.OutlinedButton{
                        .label = "Show Network Snackbar",
                        .icon = .wifi,
                        .on_press = .of(state, Showcase.State.showNetworkSnackbar),
                    }),
                },
            }),
            cx.make(ui.Snackbar{
                .message = "Inline snackbar preview with an action button",
                .action_label = "Action",
                .on_action = .of(state, Showcase.State.addClick),
            }),
        },
    });
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");

fn checkNoOverflow(n: *ui.Node) !void {
    try testing.expect(!n.overflow.any());
    for (n.children.items) |ch| try checkNoOverflow(ch);
}

test "every page of the showcase fits without overflowing across window sizes and themes" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var doc = try ui.TextDocument.init(testing.allocator, initial_notes);
    defer doc.deinit();
    const app: Showcase = .{ .doc = &doc };

    for ([_][2]u32{ min_size, open_size, .{ 1920, 1080 } }) |size| {
        for ([_]Page{ .actions, .inputs, .containers, .feedback }) |page| {
            u.frame(size[0], size[1], 0, app);
            const st = u.root.?.state(Showcase.State);
            st.page = page;
            st.sub_tab = 0;
            st.light_theme = false;
            u.frame(size[0], size[1], 1, app);
            try checkNoOverflow(u.root.?);

            // Also check light theme and second sub-tab on Containers.
            st.light_theme = true;
            st.sub_tab = 1;
            u.frame(size[0], size[1], 2, app);
            try checkNoOverflow(u.root.?);
        }
    }
}
