//! Dazzle's widget toolkit: declarative, like Flutter. An app describes
//! its UI as a tree of widgets, made again each frame from its state;
//! the toolkit keeps what persists (state, layout) between frames, lays
//! the tree out, paints it with the `gfx` canvas and sends it pointer
//! events. It follows Material 3.
//!
//! There is one kind of widget: any struct. One with `build` is made of
//! other widgets, and one with a `State` type keeps that state between
//! frames (so there is no separate stateless and stateful widget):
//!
//!     const Counter = struct {
//!         label: []const u8,
//!         pub const State = struct {
//!             count: u32 = 0,
//!             fn add(s: *State) void { s.count += 1; }
//!         };
//!         pub fn build(self: *const Counter, cx: *ui.Context, state: *State) ui.Widget {
//!             return cx.make(ui.Row{ .spacing = 12, .children = &.{
//!                 cx.make(ui.Text{ .text = cx.fmt("{s}: {d}", .{ self.label, state.count }) }),
//!                 cx.make(ui.OutlinedButton{ .label = "Add", .on_press = .of(state, State.add) }),
//!             } });
//!         }
//!     };
//!
//! Any struct with `paint` draws whatever it likes: shapes and text on the
//! canvas (`p.canvas()`), or its own draws straight into the GPU frame
//! (`p.gpu(...)`, as the demo's spinning cube does), layered in the
//! tree's order. `layout` and `event` give it its own size and input.
//!
//! Unlike Flutter, layout never fails: unbounded space, impossible
//! constraints and children that do not fit all still give a layout. What
//! overflows is clipped and its edges are striped black and yellow. It is
//! better to look wrong than not to work.
//!
//! * `widget`: `Widget`, `Context`, `Node` (the tree kept between frames)
//! * `geometry`: sizes, constraints, insets, alignment
//! * `widgets`: Row, Column, Expanded, Padding, Align, Center, SizedBox,
//!   ConstrainedBox, Grid, Overlay, Decorated, Pressable
//! * `scroll_view`: ScrollView
//! * `lazy_grid`: LazyGrid, a grid that makes only the items that show
//! * `icon`: Icon, a Material icon
//! * `text`: Text
//! * `material`: the theme, OutlinedButton, Spinner
//! * `controls`: Checkbox, Radio, Switch
//! * `text_field`: TextField
//! * `title_bar`: TitleBar, the bar apps draw across the top of their window
//! * `keymap`: key codes to characters
//! * `painter`: painting, GPU draws and the overflow stripes
//! * `damage`: what changed between frames, so only that is redrawn
//! * `runtime`: `Ui`, which runs it all

pub const geometry = @import("geometry.zig");
pub const widget = @import("widget.zig");
pub const widgets = @import("widgets.zig");
pub const text = @import("text.zig");
pub const material = @import("material.zig");
pub const controls = @import("controls.zig");
pub const text_field = @import("text_field.zig");
pub const title_bar = @import("title_bar.zig");
pub const scroll_view = @import("scroll_view.zig");
pub const lazy_grid = @import("lazy_grid.zig");
pub const icon = @import("icon.zig");
/// The icons there are (`icons.Icon`), and their font.
pub const icons = @import("icons");
pub const keymap = @import("keymap.zig");
pub const painter = @import("painter.zig");
pub const damage = @import("damage.zig");
pub const runtime = @import("runtime.zig");

pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Constraints = geometry.Constraints;
pub const Insets = geometry.Insets;
pub const Alignment = geometry.Alignment;

pub const Widget = widget.Widget;
pub const Context = widget.Context;
pub const Node = widget.Node;
pub const Event = widget.Event;
pub const Callback = widget.Callback;
pub const ValueCallback = widget.ValueCallback;

pub const Empty = widgets.Empty;
pub const SizedBox = widgets.SizedBox;
pub const ConstrainedBox = widgets.ConstrainedBox;
pub const Padding = widgets.Padding;
pub const Align = widgets.Align;
pub const Center = widgets.Center;
pub const Row = widgets.Row;
pub const Column = widgets.Column;
pub const Expanded = widgets.Expanded;
pub const Grid = widgets.Grid;
pub const Overlay = widgets.Overlay;
pub const Decorated = widgets.Decorated;
pub const Border = widgets.Border;
pub const Pressable = widgets.Pressable;
pub const Interaction = widgets.Interaction;
pub const MainAxisAlignment = widgets.MainAxisAlignment;
pub const CrossAxisAlignment = widgets.CrossAxisAlignment;
pub const MainAxisSize = widgets.MainAxisSize;

pub const Text = text.Text;
pub const TextStyle = text.TextStyle;
pub const TextAlign = text.TextAlign;

pub const Theme = material.Theme;
pub const OutlinedButton = material.OutlinedButton;
pub const Spinner = material.Spinner;
pub const Checkbox = controls.Checkbox;
pub const Radio = controls.Radio;
pub const Switch = controls.Switch;
pub const TextField = text_field.TextField;
pub const TitleBar = title_bar.TitleBar;
pub const ScrollView = scroll_view.ScrollView;
pub const LazyGrid = lazy_grid.LazyGrid;
pub const Icon = icon.Icon;

pub const Painter = painter.Painter;
pub const GpuArea = painter.GpuArea;
pub const Ui = runtime.Ui;

test {
    _ = geometry;
    _ = widget;
    _ = widgets;
    _ = text;
    _ = material;
    _ = controls;
    _ = text_field;
    _ = title_bar;
    _ = scroll_view;
    _ = lazy_grid;
    _ = icon;
    _ = keymap;
    _ = painter;
    _ = damage;
    _ = runtime;
    _ = @import("tests.zig");
}
