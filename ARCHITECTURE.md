# Dazzle's architecture

How Dazzle is made, for working on it: how to build it, what is in it and
how it works. [README.md](README.md) is about using it.

Dazzle is an ultra-light operating system for the Raspberry Pi, written in
Zig on top of a minimal mainline Linux kernel. It runs on the Raspberry Pi
Zero / Zero W (BCM2835) and the Raspberry Pi 3 A+ (BCM2837), from the same
SD card image. It is named after dazzle camouflage's zig-zags, and written
in Zig.

Dazzle is its own stack. Everything draws with **`vc4`**, a low-level
API for the VideoCore IV GPU written in Zig on the kernel's `vc4` driver:
programs record draw calls into frames themselves, with shaders written in
Zig, compiled by Zig to SPIR-V and from that to the GPU's code when
Dazzle is built. There is no OpenGL layer: the one Dazzle had, for porting existing
apps, is in the git history if it is needed again.

On top of it is **dazzle-shell**, a minimal Wayland compositor. Init (PID 1, the only process with root
privileges) starts the shell as an unprivileged user. Its dock along the
bottom of the screen has an icon for each app; clicking one starts the app
as a Wayland client, or brings its window to the front if it is already
running. USB mice, keyboards and touchscreens work: the shell shows a
cursor and passes input to the window. The demo, a native app built
with Dazzle's widget toolkit, shows a spinning, depth-tested Platonic
solid, with Material 3 buttons to change its speed, radio buttons to
choose the solid and switches to turn its lighting and texture on and
off. Rings spread out and fade
where the pointer clicks in it. Rendering statistics and the last key pressed
appear in its top left, in Fira Sans.
The settings app shows the build, the hardware, how much CPU, memory, GPU
memory and storage is in use, and the Ethernet and Wi-Fi status, and joins
Wi-Fi networks. The Files app browses the system's files: a tree of
folders, and the open folder's contents as a grid of icons. A Vulkan-style
API may follow.

## Building

### Requirements

- Zig 0.16.0. `scripts/zig` downloads it into `build/zig/` on first use
  (checked against the SHA-256 in ziglang.org's release index) unless a
  `zig` 0.16.0 is already on your PATH, so installing Zig is optional.
- To build the kernel: `make`, `flex`, `bison`, `bc`, `git`, and either
  LLVM 17 or newer (used by default; `sudo apt install clang lld llvm`) or
  an ARM GCC cross compiler (`-Dcross-compile=arm-linux-gnueabihf-`).
- To fetch the Raspberry Pi firmware: `curl`.
- Optional, for the QEMU boot test: `qemu-system-arm` (for the Zero) or
  `qemu-system-aarch64` (for the Pi 3 A+), and `fdtput` (`sudo apt install
  qemu-system-arm device-tree-compiler`; on Ubuntu releases with a hardware
  enablement stack the QEMU package is `qemu-system-arm-hwe`).

The build checks for these before it needs them and names any packages to
install. The SD image is written by a Zig tool, so no partitioning or
filesystem tools (or root) are needed.

### The image

One command builds everything into an SD card image:

```sh
scripts/build    # zig-out/dazzle.img, and its files in zig-out/boot/
```

It says what it will build, shows Zig's progress as it does, and ends by
saying what is in the image and how to write it to a card. It takes the
same options as `zig build` (`scripts/build --release=fast`); `scripts/zig
build` alone does the same build without the words.

That builds the programs and the initramfs. It clones Linux v7.2 into
`build/linux` on first use, and builds the kernel in `build/kernel` with
`make`. It downloads the firmware into `build/firmware`, checked against
pinned SHA-256 digests. Then it writes the image. Each part is redone only
when needed: a rebuild with nothing changed takes about 20 seconds (most of
it `make` checking the kernel), and the first build a few minutes. The Pi
programs are optimized for size (ReleaseSmall) unless `--release=fast`,
`--release=safe` or `-Doptimize=` says otherwise.

Other steps:

```sh
scripts/zig build test              # host unit tests
scripts/zig build programs          # just the programs and zig-out/initramfs.cpio
scripts/zig build shaders           # just the shader programs (zig-out/shaders)
scripts/zig build kernel            # just the kernel
scripts/zig build qemu              # boot in QEMU as a Zero (-Dqemu-board=pi3a+ for the Pi 3 A+; arguments after -- go to QEMU)
```

Options: `-Dlinux=path/to/linux` uses an existing kernel tree,
`-Dcross-compile=arm-linux-gnueabihf-` builds the kernel with GCC instead of
LLVM, `-Dimage-size=<MiB>` sets the image size (by default it is just big
enough for its files, with a quarter to spare: about 12 MiB, a FAT16 boot
partition after the partition table's first MiB) and
`-Dhttp-port=<port>` the host port for QEMU's log server (default 8080).

The image's boot partition:

```
bootcode.bin start.elf      the firmware, which must be here: one copy
fixup.dat LICENCE.broadcom
config.txt                  the firmware's settings; os_prefix picks the OS slot
slot-a/                     OS slot A: a whole system (zImage, the boards'
                            device trees and overlays/, initramfs.cpio,
                            version, and cmdline.txt, with dazzle.slot=a)
slot-b/                     OS slot B: the same, with dazzle.slot=b; made on
                            the card on the first start
apps/                       the apps the image comes with, one copy for
                            both slots (copied to /data/apps)
```

Everything but the firmware, the apps and `/data` has two copies, so that
an update can write the slot not in use and switch `os_prefix` to it,
keeping the other to fall back to (see Updating the system). Slot A
starts. The firmware
loads the slot's kernel, device tree and initramfs into memory; init
mounts the partition, read-only, at `/boot`; the rest of the card is
`/data` (below). The apps are the user's, in `/data/apps`, shown at
`/apps` (see Installing apps, below); until setup has made `/data`, `/apps`
shows the boot partition's `apps/`.

The image holds slot A only, to stay small, but its partition is laid out
(`mkimage --grow-to`) for one ending at 128 MiB: its clusters, FATs and
root directory are sized for that. On the first start, init grows it
before mounting it (`src/init/storage.zig`), changing only its length in
the partition table and its boot sector, as nothing follows it yet; then,
while setup runs, the system manager copies slot A to `slot-b/` a slice
at a time (`src/init/slots.zig`), writing `slot-b.new/` and renaming it
when it is whole (and starting again on the next start if it was cut
off, even once setup has finished). The partition has room for both slots to grow several times over,
as it cannot grow once `/data` follows it.

The kernel comes from `make tinyconfig` plus `kernel/dazzle.config`. The
build fails if any requested option is dropped because a dependency is
missing. The result is a zImage of about 2 MB that includes the vc4 DRM
driver, networking and the USB Ethernet drivers.

One 32-bit kernel serves both boards: it is built for ARMv6 (the Zero's
ARM1176) and ARMv7 (the Pi 3 A+'s Cortex-A53, which the firmware starts
in AArch32), with SMP for the A+'s four cores (on the Zero's single core
the SMP-only instructions are patched out at boot). The programs are
ARMv6 code, which the A53 runs as it is. The firmware picks each board's
device tree (`config.txt`).

### Continuous integration

`.github/workflows/image.yml` runs on every push and pull request: the
host tests (`scripts/zig build test`), then the image (`scripts/build`),
compressed with xz and kept as the run's artifact. On a push to the default
branch it also replaces the `latest` release's image, which README.md's
download link points to (`releases/latest/download/dazzle.img.xz`), with a
SHA-256 sum beside it, and with it the apps: each app's archive
(`<name>.tar.xz`) and the catalogue describing them (`apps.json`), which
the settings app downloads from there (`zig-out/apps`; see Installing
apps), and the system as an update (`dazzle-os.tar.xz`, with `os.json`
describing it; `zig-out/os`; see Updating the system).

Building the kernel is most of a first build, so CI caches what it can
reuse: Zig (keyed on `scripts/zig`), the Linux source (keyed on
`linux_version`, without its `.git`), the kernel's build directory
`build/kernel` (keyed on the version, `kernel/dazzle.config` and the device
tree sources; a change starts from the last one, and `make` rebuilds only
what changed) and the firmware downloads. With those, a build with the
kernel unchanged runs `make` only to find nothing to do. Zig's own cache
is not kept: everything else builds from scratch in about half a minute.

### Faster development loops

- **Raspberry Pi OS:** `zig-out/bin/dazzle-shell` and `dazzle-demo`
  also run as normal programs on Raspberry Pi OS (Lite, or with the desktop stopped) on any Pi
  from the Zero to the Pi 3. All of them have the same VideoCore IV and
  `vc4` driver. From a text console, as a user in the `video` and `input`
  groups, run the shell with `XDG_RUNTIME_DIR` set (it then listens there,
  as other compositors do, and tells the programs it starts):
  `dazzle-shell path/to/dazzle-demo`. Without `/os/fonts`, each program
  looks for `FiraSans-Regular.ttf` next to its executable, so copy
  `fonts/FiraSans-Regular.ttf` there (`dazzle-demo` also takes a font
  path as its argument). Press Ctrl+C to stop.
  Iterating on GPU code this way avoids rebuilding the SD card.
- **QEMU:** `scripts/zig build qemu` boots the kernel and initramfs in QEMU's
  `raspi0` machine with an emulated USB network card; `-Dqemu-board=pi3a+`
  uses its `raspi3ap` machine instead. QEMU starts its Pi 3 in 64-bit mode
  (the real firmware starts a 32-bit kernel in 32-bit mode), so a small
  stub (`tools/aarch32boot.zig`) switches to 32-bit mode first; QEMU's
  other cores wait in a 64-bit loop the kernel cannot use, so it runs on
  one. `http://localhost:8080/`
  reaches the log server. QEMU does not emulate the 3D engine or HDMI,
  so this checks the kernel, init, privileges and networking only. To
  try the SD card, give QEMU a copy of the image grown to a power of two
  (`truncate -s 512M card.img`) after `--`: `-drive
  file=card.img,if=sd,format=raw`; init then mounts `/boot` and `/apps`,
  and `/data` if setup has prepared it (without a card there are no apps,
  which QEMU could not draw anyway). The log
  ends with `dazzle-shell: error: NoVc4Device` and `dazzle: shell exited
  with status 1`.

## Layout

The code is split into Zig modules, linked statically into each program:

| Module | Path | Contents |
|---|---|---|
| `sys` | `src/sys/` | Linux system call helpers (sleeping, clocks, logging, the kernel command line) |
| `vc4` | `src/vc4/` | The low-level graphics API for the VideoCore IV, described below |
| `shader` | `src/shader/` | Shaders written in Zig: SPIR-V translated to `vc4` programs, and pipelines for drawing with them |
| `app` | `src/app/` | Native apps' windows on dazzle-shell: buffers shared with the shell, frame pacing and input, and the system's clipboard (`clipboard.zig`: text copied as a Wayland data source, and pasted from the selection's offer through a pipe, read as the window's event loop sees it come, so the app goes on meanwhile) |
| `gfx` | `src/gfx/` | 2D graphics for the toolkit: anti-aliased rounded rectangles, circles, polygons and polylines, filled or stroked, and text, blended |
| `ui` | `src/ui/` | The widget toolkit: declarative widgets with state, layout, painting and input, in Material 3's style |
| `font` | `src/font/` | OpenType font rendering, described below |
| `icons` | `src/icons/` | Material icons: the ones Dazzle uses (`Icon`), and a font with just those, made from the full Material Icons font by `tools/subset_icons.zig` when building (as Flutter leaves out the icons an app does not use) and built into the programs; the toolkit draws them with `ui.Icon` |
| `wayland` | `src/wayland/` | The Wayland wire protocol (with file descriptor passing), the interfaces Dazzle uses, and a small client library |
| `dazzle-init` | `src/init/` | The init program: mounts (the SD card's boot partition, its apps at `/apps`), the SD card's space for files (partitioning and formatting it on the first run), network, Wi-Fi, log server, device permissions, starting the shell |
| `dazzle-shell` | `src/shell/` | The Wayland compositor and shell, described below |
| `dazzle-demo` | `src/demo/` | The demo, a native app |
| `dazzle-setup` | `src/setup/` | The setup app, on the first run only: names the computer while the SD card is prepared |
| `dazzle-settings` | `src/settings/` | The settings app: the build, the hardware, what is in use and the network |
| `dazzle-files` | `src/files/` | The Files app: a tree of folders and a grid of what is in the open one |
| `dazzle-camera` | `src/camera/` | The Camera app: the Camera Module's frames, made pictures of on the CPU, and photos |

The `vc4` module:

| File | Contents |
|---|---|
| `device.zig` | GPU buffers, shader upload and job submission (`vc4` ioctls) |
| `compiler.zig` | Shader compiler: SSA builder, register allocation and QPU code generation, with threaded fragment shaders |
| `qpu_schedule.zig` | Instruction scheduler: latency-aware reordering and add/mul pairing |
| `render.zig` | Records a frame: any number of draw calls into one render target, as one job |
| `texture.zig` | Texture tiling (T and LT layouts, for 32- and 16-bit pixels) and texture unit configuration |
| `format.zig` | The pixel formats (XRGB8888, ARGB8888, RGB565, and A8 for textures): their sizes, codes, and how the tile buffer stores them and the texture unit reads them |
| `display.zig` | Double-buffered scanout with page flips at vertical blank, and showing other buffers on the display's planes |
| `drm.zig` | DRM core and KMS (mode setting, page flip, cursor) ioctls |
| `kms.zig` | Atomic mode setting: the primary and an overlay plane, set in one commit per frame |
| `cl.zig` | Binning control list packets and shader record layout |
| `qpu.zig` | QPU instruction encoder, hazard checker, instruction pairing and disassembler |
| `qpu_sim.zig` | QPU simulator used by the tests to run shaders on the build machine |
| `reference_shaders.zig` | The original hand-written triangle shaders, known to work on hardware |

The `gfx` module draws 2D shapes, the toolkit's foundation:

| File | Contents |
|---|---|
| `canvas.zig` | `Canvas`: records shapes and text (on the CPU) into batches of vertices: rectangles with per-corner radii, circles, polygons and polylines, filled or stroked, and lines of text, with an origin and a clip rectangle |
| `atlas.zig` | `Atlas`: glyphs rasterized by the font renderer, packed into one 8-bit (A8) texture of their coverage, and the text runs laid out recently |
| `geometry.zig` | Polygon triangulation (ear clipping, concave polygons included) and stroke strips with mitred joins, with anti-aliasing fringes |
| `shaders/` | The 2D shaders (`shape.zig`, `solid.zig`, also built without blending as `opaque`, and `text.zig`) |
| `shaders.zig` | The 2D shader programs, as the build compiled them, and their vertex layouts |
| `renderer.zig` | `Renderer`: draws canvases into a `vc4` frame (several per frame, with other draws between them), and uploads the glyphs added to the atlas |
| `preview.zig` | Renders a canvas on the CPU through the real shaders (in the QPU simulator), for tests and preview images |

Everything is anti-aliased and blends over what is below it: the fragment
shaders read the tile buffer's colour and mix (source-over, straight
alpha), which the hardware supports without a blend unit. Rounded
rectangles are cut into a 3x3 grid: the four corner cells compute the
exact distance to the rounded outline per pixel (with exact coverage at
square corners), while the edges and centre are plain triangles whose
straight edges fade over a one-pixel fringe. So the costlier shader only
runs over the corners, and a stroked rectangle skips its inside entirely.
Polygons and polylines are triangulated on the CPU with the same fringes.
Shapes of one kind are drawn together when nothing drawn in between
overlaps them, so a screen of separate cards is a few draws.

Blending costs a wait for the tile buffer and arithmetic per pixel, so
triangles that are opaque all over (the insides of filled shapes and the
cores of strokes, in an opaque colour) are drawn with the solid shader
compiled without blending; only the anti-aliased fringes, the corner
cells, text and translucent shapes blend. Within a shape the order does
not matter (blending a colour over itself gives the same colour), and the
result is the same, pixel for pixel.

Text is drawn by the GPU too: each glyph is a quad sampling its coverage
from the atlas, in the text's colour, blended like the shapes. Glyphs are
placed to a quarter of a pixel (each quarter rasterized once), and match
the font renderer's own drawing to within one level per channel. Text
laid out once (character map lookups and kerning, the costly part) is
kept while it is drawn each frame. The atlas holds only coverage, one
byte a texel (an A8 texture, the texture unit's ALPHA type, which gives
it as alpha): 512 KB of GPU memory per app (and as much for its copy on
the CPU) rather than 2 MB at 32 bits.

The `ui` module (`src/ui/`) is the widget toolkit. Like Flutter, it is
declarative: an app describes its window as a tree of widgets, made again
each frame from its state, and the toolkit keeps what lasts between frames.
There is one kind of widget, any struct: one with `build` is made of other
widgets, and one that declares a `State` type also keeps that state for as
long as it stays at its place in the tree (by position and type, or by
key). There is no separate stateless and stateful widget:

```zig
const Counter = struct {
    label: []const u8,

    pub const State = struct {
        count: u32 = 0,
        fn add(s: *State) void {
            s.count += 1;
        }
    };

    pub fn build(self: *const Counter, cx: *ui.Context, state: *State) ui.Widget {
        return cx.make(ui.Row{ .spacing = 12, .children = &.{
            cx.make(ui.Text{ .text = cx.fmt("{s}: {d}", .{ self.label, state.count }) }),
            cx.make(ui.OutlinedButton{ .label = "Add", .on_press = .of(state, State.add) }),
        } });
    }
};
```

Any struct with `paint` draws whatever it likes: shapes and text on the 2D
canvas, or its own draws straight into the GPU frame, layered in the
tree's order. The demo's spinning solid is one: a widget whose `paint`
adds a draw of the solid with the widget's box as the viewport. `layout` sizes a widget
within the constraints its parent gives (Flutter's box constraints) and
places its children, and `event` takes pointer events.

Unlike Flutter, layout never fails. Unbounded space, impossible or
nonsensical constraints and sizes (NaN, negative, infinite), and flexible
children with no space to share all still give a layout. Children that
reach past their parent are clipped to it, and the edges they overflow
are striped black and yellow, so a layout that does not fit still shows,
with the problem marked.

| File | Contents |
|---|---|
| `widget.zig` | `Widget`, `Context` (for `build`), `Callback`, and `Node`: the tree kept between frames, matching each frame's widgets to it, layout and hit testing |
| `geometry.zig` | Sizes, constraints (made usable whatever they are), insets, alignment |
| `flex.zig` | `Row` and `Column` (both `Flex`): children one after another, with their alignments |
| `expanded.zig` | `Expanded`: a share of the space the other children of a row or column leave |
| `padding.zig`, `align.zig`, `center.zig`, `sized_box.zig`, `constrained_box.zig`, `empty.zig` | `Padding`, `Align`, `Center`, `SizedBox`, `ConstrainedBox` and `Empty`: placing and sizing a child |
| `grid.zig` | `Grid`: cells in rows, as many to a row as fit |
| `lazy_grid.zig` | `LazyGrid`: a grid (or list) of many items all the same size, of which only those that show are made |
| `overlay.zig` | `Overlay`: layers over each other |
| `decorated.zig` | `Decorated`: a filled or outlined rounded rectangle behind the child |
| `pressable.zig` | `Pressable`: clicks, hover and press |
| `icon.zig`, `image.zig` | `Icon` (a Material icon) and `Image` (pixels, as big as they fit) |
| `text.zig` | `Text`: lines at `\n`, wrapped at spaces to fit, or cut short with "…" |
| `scroll_view.zig` | `ScrollView`: the part of a taller child scrolled to, with the wheel or by dragging its bar, and scrolling to a widget in it (`reveal`) |
| `theme.zig` | `Theme`: Material 3's light and dark baseline colour schemes, and text sizes |
| `outlined_button.zig` | `OutlinedButton`, made of a `Pressable`, `Decorated`, `ConstrainedBox`, `Padding` and `Center`, with a label, an icon or both |
| `spinner.zig` | `Spinner`: Material's indeterminate circular progress indicator |
| `checkbox.zig`, `radio.zig`, `switch.zig` | Material 3's selection controls: `Checkbox`, `Radio` (generic over the value it selects) and `Switch` (its handle slides), each with an optional label that presses it too; `control.zig` has what they share |
| `text_field.zig` | `TextField`: a line of text to type (Material's outlined field), optionally shown as dots for passwords; clicking it gives it the keyboard. Text is selected by dragging, or with Shift and the arrow keys, Home and End (Ctrl+A: all); Ctrl+X, Ctrl+C and Ctrl+V cut, copy and paste, and so does the menu the right button (or holding a touch down) shows. A password cannot be cut or copied |
| `menu.zig` | `Menu`: Material's menu of actions, which `Ui.openMenu` shows above everything at a point (down and right of it, flipped up or left where there is no room, and kept in the window); pressing an item closes it and does the action, and pressing elsewhere or Escape closes it. The runtime asks the widget under the pointer for one (`Event.context`) when the right button is pressed, or a touch is held for half a second without moving |
| `title_bar.zig` | `TitleBar`: the bar apps draw across the top of their window, with their name, maximize and close buttons, and dragging it to move the window (the shell draws none) |
| `bar_button.zig` | `BarButton`: the title bar's round icon buttons |
| `keymap.zig` | Linux key codes to characters, for a US keyboard (the shell sends key codes without a keymap) |
| `painter.zig` | Painting: canvas layers and GPU draws in order, clipping (nothing outside the clip is painted), and the overflow stripes |
| `damage.zig` | What changed between frames: each node's drawing fingerprinted and compared, kept as a few rectangles, with a history for buffers of any age |
| `runtime.zig` | `Ui`: builds, lays out and paints each frame, records it into a `vc4` frame (or draws it on the CPU, for tests), and sends pointer events (and the wheel) to the widgets under the pointer. A touch (one at a time) acts as the left button: a tap clicks; held, it asks for a menu; moved, it pans what can scroll under it (following the finger exactly, and pressing nothing), or else drags |
| `tests.zig` | Tests: overflow, nonsense layouts, state and keys, buttons, overlays, GPU draws' order, rows and columns, controls, damage, grids and scrolling |

`Overlay` stacks layers, each filling it, and the topmost layer with
something under the pointer gets the event. A button press takes the
pointer until it is released; releasing over the button is a click.

Only what changes is drawn again. While painting, the canvas fingerprints
each node's own drawing (every shape with its position, colour and clip,
and the node's place in the painting order) and notes the area it
covers. A node whose fingerprint or area differs from the last frame
damages its old and new areas; so does a node no longer painted, or
removed. GPU draws cannot be seen into, so they count as changed every
frame unless their widget gives a key and the area it draws in (the
demo's solid gives its time, shape and look, and the outline of its
bounding sphere: paused, it costs nothing). The damage is kept as up to
four rectangles.

A window's buffers are reused in turn, so a buffer last drawn some frames
ago (its age) misses the damage since: `repaint` gives what it needs from
a short history of damage. A `vc4` frame can be limited to those
rectangles (`Frame.limitTo`): the kernel renders only the 64-pixel tiles
covering them (one job per group of tiles), every other tile of the
buffer keeps its picture, and draws entirely outside them are not even
recorded. A frame that changed nothing is not drawn or shown at all, and
the app sleeps until something happens. The shell is told which parts
changed (`damage_buffer`).

No intermediate buffers are used: with tile-limited rendering, unchanged
parts cost nothing, and nothing in the demo is both costly to draw and
under something that changes. The glyph atlas and the shell's dock (an
overlay plane) are the retained buffers there are.
Each frame that is drawn is still built, laid out and painted whole on the
CPU (about 40 µs on a desktop for the demo).

The `app` module gives a native app a window: a Wayland toplevel on the
shell, with up to three buffers the GPU renders into in its T-tiled layout,
shared with the shell as dma-bufs (announced with the
`BROADCOM_VC4_T_TILED` modifier, as Mesa's vc4 driver also does), so the
shell can show them without copying. `beginFrame` gives the render target
for the next frame (a buffer the shell has released); `present` renders the
frame and hands it to the shell once the previous one is on the screen, so
at most one frame is queued. It also delivers the seat's pointer and
keyboard events.

A window's buffers are RGB565 unless the app asks for 32 bits
(`setFormat`): half the memory, and half the memory traffic to draw,
composite and show them. Everything is drawn in the tile buffer in 32-bit
colour, as before, so the shaders do not change; only how the tile buffer
is stored to the buffer (and loaded back, when part of a frame is redrawn)
does. It is stored without dithering, so pixels loaded and stored again
stay as they were. Dazzle's apps draw opaque windows of flat colours,
which 16 bits show with little loss (gradients band a little); the demo
has a switch to compare the two.

The `shader` module (`src/shader/`) runs shaders written in Zig. A shader
program is a Zig file with a vertex and a fragment entry point; it imports
`gpu` (`gpu.zig`) for its inputs, outputs, uniforms and texture:

```zig
const gpu = @import("gpu");

const Uniforms = extern struct { mvp: [4]gpu.Vec4 };
const u = gpu.uniforms(Uniforms);
const in_pos = gpu.vertexInput(gpu.Vec3, 0);
const in_uv = gpu.vertexInput(gpu.Vec2, 1);
const v_uv = gpu.vertexOutput(gpu.Vec2, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];
    v_uv.* = in_uv.*;
}

const f_uv = gpu.fragmentInput(gpu.Vec2, 0);

export fn fragment() callconv(.spirv_fragment) void {
    gpu.color.* = gpu.texture(f_uv.*);
}
```

The build compiles each program with Zig's SPIR-V backend, then
`tools/shaderc.zig` translates the SPIR-V to the GPU's three shaders
(coordinate, vertex and fragment), with the render state that changes
their code (depth testing, blending), and the program that uses it embeds
the result. Shaders are static, so this costs nothing when Dazzle runs,
and a shader that cannot be compiled fails the build, naming the line. The
same code can compile SPIR-V when an app runs (`Program.compile`), and the
tests check that it gives exactly what the build embedded.

| File | Contents |
|---|---|
| `gpu.zig` | What shaders import as `gpu`: vector types, inputs and outputs by location, the uniform block, the position, the colour, texture sampling and helpers |
| `spirv.zig` | Reading SPIR-V modules: types, constants, decorations, functions and entry points, with source lines |
| `lower.zig` | Lowering an entry point to the vc4 compiler's builder, one value per scalar component, functions inlined, control flow predicated and loops unrolled; it adds the vertex's screen-space header, and the fragment's depth write and blending |
| `program.zig` | `Program`: linking the entry points by location, deriving the coordinate shader (reading only the attributes the position needs), and the encoding programs are embedded in |
| `pipeline.zig` | `Pipeline`: a program uploaded to the GPU with its vertex layout, culling and primitive, recording draws into a `vc4` frame |
| `tests.zig` | Tests of the built programs in the QPU simulator, and of compiling them again from SPIR-V |

Supported so far: `f32` scalars and vectors, arithmetic (division
included), `@min`, `@max`, `@abs`, `@sqrt`, `@exp2`, `@log2`, `@mulAdd`
and `@reduce(.Add, ...)`, helper functions, local variables, vertex
inputs, varyings, one uniform block of floats, vectors and arrays, and one
texture. Control flow works too: comparisons, `if`, `switch`, `@select`,
early returns, and loops (`while`, `for`, `break`). The compiler has no
branches, so it is lowered by predication: the 16 lanes of a QPU each take
their own way, every block some lane takes runs for those lanes, and
variables keep their old values in the others. So both sides of an `if`
cost time when the lanes differ, and loops are unrolled: they must stop
after a number of iterations known when the shader is compiled (a `break`
that depends on the data is fine). Integer arithmetic beyond loop
counters, `@floor` and the trigonometric built-ins are not there yet.

The 2D shaders' programs draw the `gfx` showcase identically to the
builder-API versions they replaced, and the demo's are checked in the
simulator against the same maths done on the CPU.

The shell (`src/shell/`):

| File | Contents |
|---|---|
| `main.zig` | Opens the GPU and display, listens on `/os/sockets/wayland-0`, and runs the event loop: read input (clicks on the dock start or raise apps), dispatch clients, then composite a frame when something changed |
| `server.zig` | The Wayland server: clients, objects and requests, frame callbacks and buffer releases, window stacking, maximizing and moving, pointer and keyboard focus |
| `render.zig` | Compositing with the `vc4` API: textured quads for the panels (the dock) and the windows, and the cursor plane |
| `dock.zig` | The dock: finds the apps in `/apps`, draws their icons, and finds the one clicked |
| `shaders/quad.zig` | The textured quad's shader |
| `input.zig` | USB keyboards, mice and touchscreens: finds `/dev/input/event*` nodes and decodes their events (a touchscreen's multitouch slots, or a single touch, as touches going down, moving and coming up) |
| `cursor.zig` | The pointer's pictures (an arrow, and arrows for resizing), drawn into the cursor plane's buffer |
| `screenshot.zig` | Print Screen: the screen saved as `/data/user/Screenshot N.png` |
| `png.zig` | Writing PNG images |
| `placement.zig` | Where popups go: their positioners, and flipping, sliding or cutting them to fit the work area |
| `keyboard.zig`, `us.xkb` | The keyboard for clients: a US XKB keymap, and the modifiers' state |
| `server_test.zig`, `protocol_test.zig` | Protocol tests on the host, described below (`protocol_test.zig`'s run the server and clients on one thread, step by step) |

The server offers `wl_compositor`, `wl_subcompositor`, `wl_shm` (ARGB8888,
XRGB8888 and RGB565, copied to a texture at commit), `zwp_linux_dmabuf_v1`
(T-tiled buffers in the same formats),
`xdg_wm_base` (toplevels and popups), `wl_output`, `wl_seat` (a pointer and
a keyboard), `wl_data_device_manager` (copy and paste) and
`wp_cursor_shape_manager_v1` (the pointer's picture, by name): what common
Wayland clients expect, with the parts below left out. Damage and regions
are accepted and ignored (the shell draws whole surfaces, and the whole of
a surface takes the pointer); buffer scales other than 1 and transforms are
refused.

- **Output:** one, the screen: its mode (size and refresh rate), scale 1
  and name. Surfaces are told they are on it (`wl_surface.enter`) when
  first shown.
- **Subsurfaces:** drawn above their parent, at the place it gives (which
  takes effect when the parent is committed), in the order `place_above`
  and `place_below` give, and taking the pointer where they are. Their
  state is applied when they are committed, as if desynchronized.
- **Popups:** menus and tooltips, above their parent's window, placed by
  their positioner (its anchor rectangle, anchor, gravity and offset).
  One that would go outside the work area is adjusted as its positioner
  allows, on each axis: flipped to the other side of its anchor (if that
  fits), then slid in, then cut to fit (`src/shell/placement.zig`). A
  reactive one is placed again when its window moves. A popup that grabs (a menu)
  takes the keyboard, and is closed (`popup_done`, with the popups on it)
  when anything but its client's own surfaces is clicked, or its window
  goes. `reposition` moves one.
- **Copy and paste:** the client with the keyboard copies by setting the
  selection (a `wl_data_source` and its MIME types); a client is told what
  the clipboard holds (a `wl_data_offer`) just before it gets the
  keyboard, and when it changes, and asks for it as a MIME type, which its
  source writes into a pipe the client reads. A copy replaces the last
  (whose source is cancelled). Drag and drop is not supported yet.
  Dazzle's apps copy and paste text this way (`app/clipboard.zig`, for the
  toolkit's text fields); text an app copied it pastes from its own copy.
  Pasting does not wait: the text is read from the pipe as it comes, in
  the app's event loop (`Window.wait` watches the pipe), and put in the
  field once it has all come; an app that has not written it within a
  second has its paste dropped, and a field that has gone gets nothing.

- **Windows:** each toplevel starts maximized, filling the screen above
  the dock. Unmaximized (`unset_maximized`), it is told half the work
  area's width and height (or its minimum size, if bigger) the first
  time, in the middle of it, and afterwards the size and place it had;
  maximized again, it fills it. A restored window moves with the pointer
  once its client asks (`move`, with the serial of a button press it is
  still holding): until the button is released the pointer is the
  shell's, and the window stays where its title bar can be reached.
- **Resizing:** apps resize their windows, as Wayland clients do: a press
  near a restored window's edge or corner (within 6 pixels inside it; the
  `app` library's `Window` finds it) asks the shell to `resize` by those
  edges, and the shell follows the pointer, with the opposite edges kept
  where they are, until the button is released. A window is no smaller
  than its client's `set_min_size` (each app's `min_size`) nor bigger than
  the work area. The shell tells it a new size only once it has drawn at
  the last one (acknowledged the configure and committed), so a slow app
  is not sent sizes faster than it can draw them; while it catches up,
  what it shows stays anchored at the edge not being dragged. Over the
  edges the app asks for a resize arrow (`wp_cursor_shape_v1`), and the
  shell shows it while resizing too. Apps lay out again at every size,
  and nothing in them scales: text, buttons and spacing are the same size
  in pixels in any window, and a bigger one shows more. Windows are stacked newest on top; clicking a window, or its
  app in the dock, raises it, and the top window has the keyboard
  (`activated`). Apps draw their own title bars (the toolkit's `TitleBar`:
  the app's name, a button that maximizes or restores the window, a close
  button that quits it, and dragging the bar moves the window), so the
  shell draws none, and with no app open the screen shows just the dock.
- **Covered windows:** a window hidden behind one above it cannot be seen,
  so it is told: it gets xdg_toplevel's `suspended` state (xdg-shell
  version 6), its frame callbacks are held until it can be seen again, and
  what it commits meanwhile does not make the shell draw a frame. Dazzle's apps then stop drawing (the demo's
  solid stops spinning) and free the buffers they are not using, so the
  app in front has the GPU memory; raised, they draw again.
- **GPU memory:** every buffer the GPU touches comes from the kernel's CMA
  pool (the V3D has no MMU). At 1080p the shell's two screen buffers take
  17 MB and each window up to three 4 MB buffers (RGB565; 8 MB at 32
  bits), more than the device tree's 64 MB pool leaves once the kernel's
  binner memory is taken, so `cmdline.txt` sets `cma=128M`. An app that
  cannot get another buffer makes do with those it has, or waits for
  memory to be freed. The screen stays 32-bit: everything is composited
  into it, and screenshots are taken from it.
- **Apps:** each directory in `/apps` holding a program of the same name
  (`/apps/<name>/<name>`) is an app, with an icon in the dock: its initial
  on a coloured square, with a dot under it while it runs. Apps run once
  each: the shell knows each client's process (from its socket), and
  clicking a running app raises its window. Nothing starts until it is
  clicked, other than programs named on the shell's command line. The
  dock follows `/apps` as apps are installed and removed (see Installing
  apps).
- **Buffer sharing:** clients render with the GPU straight into buffers
  they share with the shell as dma-bufs, so nothing is copied. The GPU's
  texture unit cannot read ordinary (linear) images, so clients render in
  its T-tiled layout, and the shell draws their buffers as textures. That
  layout is announced with the `BROADCOM_VC4_T_TILED` modifier, as Mesa's
  vc4 driver also does.
- **Pixel formats:** windows' buffers are RGB565 or 32-bit (above). The
  texture unit returns an RGB565 texel's red first but a 32-bit one's blue
  first (the order the tile buffer wants), so RGB565 windows are drawn
  with a second quad shader that swaps them back (`quad_rgb565.zig`; the
  simulator samples RGB565 the way Mesa's vc4 driver says the hardware
  does).
- **Direct scanout:** the display hardware can scan out T-tiled buffers
  (32-bit and RGB565) and stack several planes. When the top window is maximized and its
  buffer is exactly the work area's size, the shell puts it on the
  display's primary plane as it is, and the dock on an overlay plane, with
  one atomic commit. Nothing is composited, which saves the GPU a
  full-screen copy and a third of the memory traffic per frame. Otherwise
  (restored windows, other sizes, shm buffers, or a driver without atomic
  mode setting) the shell composites the frame with the GPU, drawing the
  windows that can be seen from the bottom up.
- **Pacing:** the shell never waits for vertical blank: it queues each
  frame and carries on serving clients and input until the page flip
  event, then draws the next frame if anything changed. A frame callback
  fires once the frame showing it is on the screen. A buffer shown directly
  is released once a later frame replaces it on the screen; a composited
  one as soon as a newer one is committed, because the shell waits for each
  composite to finish.
- **Input:** the shell reads evdev devices itself (no libinput). Mouse
  motion moves the pointer, without acceleration, and the shell moves the
  display's hardware cursor plane, so moving it costs no new frame. The
  shown window gets the keyboard, and it gets the pointer while the pointer
  is over it, in window coordinates. Clients get an XKB keymap for a US
  keyboard (`us.xkb`, in a sealed memory file; key events carry Linux key
  codes, the keymap's less 8), and the modifiers (Shift, Caps Lock,
  Control, Alt, Num Lock, Super) as they change; they repeat held keys
  themselves, 25 a second after 600 ms. Dazzle's own apps map the key
  codes themselves (`ui/keymap.zig`). Clients choose the pointer's picture by name
  (`wp_cursor_shape_v1`: an arrow, or the resize arrows, drawn by the
  shell); their own images (`set_cursor`) are ignored.
  Devices plugged in later are found within a second.
- **Touch:** a device with absolute positions is a touchscreen (one that
  tracks several touches, or one). Its touches go to the surface they went
  down on (`wl_touch`), in its coordinates; going down, a touch brings its
  window to the top and closes another client's menus, as a click does. A
  client can move or resize its window with a touch still down (its
  `move` or `resize` with the touch's serial): the touch is then the
  shell's, and the client is told its touches are cancelled. Touches on
  the dock are the shell's: a tap there is a click.

The demo program (`src/demo/`):

| File | Contents |
|---|---|
| `main.zig` | The window (from the `app` module), the frame loop, input and timing statistics |
| `view.zig` | The window's widgets: the rings and the solid behind a column with the statistics, the speed buttons, the radio buttons choosing the solid, and the lighting and texture switches |
| `rings.zig` | The rings drawn where the pointer clicks: stroked circles on the 2D canvas, fading out |
| `solids.zig` | The five Platonic solids: meshes found from their corners (with flat normals, a tint per face and a checkerboard across each), drawn with depth testing and culling, lit and textured or not |
| `shaders/` | The solids' shader: tint, optional lighting (diffuse from a fixed light, with ambient) and optional texture |

### Privileges

Only init runs as root. Everything else runs as the Dazzle user: the
fixed user and group ID 1000 (`sys.user`). There are no accounts,
passwords or logins.

- Once vc4 has probed, init makes the DRM nodes in `/dev/dri` owned by that
  user, mode 0660. The shell is the first to open the card, so it becomes
  DRM master and can set modes and flip pages without privileges. Clients
  use the render node (`/dev/dri/renderD128`), which can render but not
  touch the display.
- The user's programs make their sockets (the shell's `wayland-0`, the
  managers' `network` and `system`) in `/os/sockets`, the one directory
  the initramfs gives the user (mode 0700); everything else in it is
  root's, and only root can write to it. Init removes `/root`, which the
  kernel's own built-in initramfs makes and nothing uses. Then it forks,
  drops to the user (no supplementary groups, then the group, then the
  user ID) and execs `/os/shell/dazzle-shell`. The shell's stdout and
  stderr are init's `/dev/kmsg` descriptor, because only root can open that
  for writing. The shell's clients inherit them.
- The network manager, the one process that configures the network (wired
  and Wi-Fi), runs as the same user but keeps three capabilities:
  `CAP_NET_ADMIN` (configuring interfaces and routes; nl80211 needs it to
  scan, connect and install keys), `CAP_NET_RAW` (the supplicant's packet
  socket, and tying DHCP's socket to the interface) and
  `CAP_NET_BIND_SERVICE` (the DHCP client port). Its socket,
  `/os/sockets/network`, answers only the settings app: every app runs
  as the same user, so the socket's permissions cannot tell them apart,
  and it checks instead which program the connecting process runs
  (`/proc/<pid>/exe`, from the socket's peer credentials). Init restarts it
  if it ever stops.
- The system manager runs only on the first run, while the setup app
  does (and until it has made OS slot B), as the user keeping three capabilities: `CAP_SYS_ADMIN` (writing
  the card's partition table, mounting, making the boot partition
  writable and setting the hostname), `CAP_DAC_OVERRIDE` (the card's
  device node, the root-owned `/data`, and the boot partition's files)
  and `CAP_CHOWN` (giving `/data/system` to root). Its socket,
  `/os/sockets/system`, answers only `/os/shell/dazzle-setup`.
- The device manager runs as the user, keeping only `CAP_CHOWN`. Input
  device nodes, and the camera's (`/dev/videoN`, `/dev/v4l-subdevN`,
  `/dev/mediaN`), are created owned by root, so it gives each one to the
  user (at start, then on each uevent that adds one), and the shell and
  the Camera app can use them. Init restarts it if it ever stops.
- The log server binds port 80 as root, then drops to the same user. Reading
  `/dev/kmsg` needs no privileges.
- Init logs how the shell exits, and the shell logs how its clients exit.
  Neither is restarted.

This needs `CONFIG_MULTIUSER` in the kernel (about 8 KB). Without it, every
process has every privilege.

Also: `build.zig` (the whole build, see below), `tools/` (host tools the
build runs: `mkinitramfs.zig` packs the initramfs, `mkimage.zig` writes the
SD card image, `check.zig` checks for build tools, the kernel
configuration and firmware checksums), `kernel/dazzle.config` (kernel
config fragment applied on top of `tinyconfig`), `boot/` (firmware
`config.txt`, kernel `cmdline.txt`, and the Pi 3 A+'s device tree:
mainline's, built by the kernel's `dtc` with one change, below), `scripts/zig` (downloads Zig) and `scripts/build` (the build, with what it makes and how to flash it).

The system's filesystem (the OS slot's initramfs, in RAM, with the card's
partitions mounted on it) is kept simple:

```
/os/                        Dazzle itself:
/os/init                      dazzle-init (rdinit=/os/init in cmdline.txt)
/os/shell/                    dazzle-shell, and its own apps (dazzle-settings
                              and dazzle-setup, which cannot be removed)
/os/NOTICES                   the third-party software built into the system's
                              programs (the icon font), and its licences
/os/fonts/                    the font every program shares, and its licence
/os/firmware/brcm/            the Wi-Fi chips' firmware, and its licence
/os/sockets/                  the shell's socket (wayland-0) and the network
                              and system managers' (network, system); the
                              user's
/boot/                      the card's boot partition, read-only: the
                            firmware, config.txt, the OS slots and the apps
/os/certs/                    the certificate authorities HTTPS trusts
                              (Mozilla's, from certifi; pinned by checksum)
/etc/resolv.conf            the name servers, written by the network
                            manager (the user's)
/apps/                      the apps (/data/apps, the user's; before setup,
                            the boot partition's apps/): dazzle-demo/,
                            dazzle-files/ and dazzle-camera/ to begin with,
                            each holding its program (and
                            <program>.icon, the name of its icon in the
                            dock; the shell's own apps have theirs beside
                            them too) and NOTICES, the third-party software
                            built into it and its licences (apps are
                            independent of the system)
/data/                      the SD card's space for files, once setup has
                            prepared it: /data/system (the computer's name,
                            and a mark that setup has finished; root's),
                            /data/user (the user's), /data/apps (the
                            apps, the user's too) and /data/update (where
                            Settings downloads updates; the user's)
/dev /proc /sys             mounted by init, for Linux
```

Dazzle's apps look for the shell on `/os/sockets/wayland-0` unless
`WAYLAND_DISPLAY` or `XDG_RUNTIME_DIR` says otherwise; other Linux programs,
once they are supported, will be given
`WAYLAND_DISPLAY=/os/sockets/wayland-0`. Programs find the font in
`/os/fonts` (`sys.fontFile`), or, run elsewhere, beside themselves.

There is no C library: programs make raw system calls through
`std.os.linux`.

## At run time

[README.md](README.md) says how to put Dazzle on a card and use it; this is
what happens underneath. The same card works in every board.

### The first run

The first time it starts, the screen shows the setup app
(`/os/shell/dazzle-setup`) and no dock. It asks for the computer's name, filled
in with a random two words (like `awesome-elephant`), on pages with Next
buttons (more pages, such as the language, keyboard and network, are to
come). Meanwhile init's system manager (`src/init/system.zig`) makes OS slot B
(above) and the rest of the card a place for files: it adds a partition from the end of the
system's (rounded up to 4 MiB) to the end of the card (`src/init/storage.zig`),
gives it an empty filesystem (`src/init/mkfs.zig`: ext2's layout with a
journal, which the kernel's ext4 driver mounts; written a few block groups
at a time, so setup can say how far it has got) and mounts it at `/data`.
After the last page, a spinner shows while that finishes, if it has not.
Then the computer is named (and the name kept in `/data/system`, for every
boot after), setup is marked done, and the dock appears. If the card
cannot be prepared (it is no bigger than the image, say), setup says why;
files are then not kept, and setup runs again at the next start. The
journal keeps the filesystem consistent through a power cut, the usual way
to turn a Pi off.

Connect HDMI, and a USB Ethernet adapter cabled to your network: on the
Zero's USB (OTG) port via a micro-USB OTG adapter, or in the Pi 3 A+'s USB
port (with a hub for the keyboard and mouse), or join a Wi-Fi network from
the settings app (open and WPA2 networks).
The kernel has drivers for
common adapter chipsets: Realtek RTL8152/8153, ASIX AX88772/AX88179, SMSC
LAN95xx, Microchip LAN78xx and generic CDC Ethernet.

### Reading the log over the network

The network never holds up boot. Init starts the network manager
(`src/init/network.zig`) alongside everything else. It waits for an
Ethernet adapter, and gets an address by DHCP once there is a link
(renewing the lease), or uses the static address chosen in the settings
app. The adapter can be plugged in or out, and the cable connected, at any
time. A log server also starts
before the GPU is touched, so the log stays readable if a GPU job hangs.
The Pi asks the DHCP server for the hostname `dazzle`, so look for that
name in your router's lease list, then open `http://<pi-address>/` in a
browser (or `curl http://<pi-address>/`). It shows the whole log since
boot: kernel, init and program messages. `http://<pi-address>/follow`
shows the same, then new messages as they arrive (`curl -N` follows it in a
terminal).

```
Dazzle 6ec3896 system log. /follow shows new messages as they arrive.

[    4.731220] dazzle: starting as init (build 6ec3896)
[    4.739512] dazzle: log server listening on HTTP port 80 as uid 1000
[    4.740011] dazzle: network: found eth0 (<mac>)
[    4.746230] dazzle: network: eth0 link up
[    4.940117] dazzle: network: eth0 is 192.168.1.42/24, gateway 192.168.1.1 (DHCP, lease 86400 s)
[    4.740312] dazzle: started /os/shell/dazzle-shell (pid 24) as uid 1000
[    4.741008] dazzle: opened /dev/dri/card0 (vc4)
[    4.772511] dazzle-shell: build 6ec3896, display <width>x<height>
[    4.772610] dazzle-shell: app Demo (/apps/dazzle-demo/dazzle-demo)
[    4.772702] dazzle-shell: listening on /os/sockets/wayland-0
[    4.773120] dazzle-shell: input: /dev/input/event0: Logitech USB Optical Mouse
[    4.791240] dazzle-shell: cursor shown
[    7.312913] dazzle-shell: started /apps/dazzle-demo/dazzle-demo (pid 25)
[    7.330100] dazzle-shell: client connected
[    4.802114] dazzle: drawing with the vc4 API, window <width>x<height>
[    9.840211] dazzle: 60.0 fps, GPU <t> ms, CPU <t> ms per frame
```

Timestamps above are illustrative, and the order varies because the network
comes up in parallel with the demo. To use a static address instead of
DHCP, choose Static under Ethernet in the settings app (it lasts until the
system stops).

### The demo

The screen shows the shell's dock along the bottom; click the demo's
icon in it to start it, and its window fills the space above, with its
title bar (with maximize and close buttons) across the top. The maximize
button restores the window to half the size, and then the title bar drags
it about and its edges resize it. The solid spins at the
display's refresh rate. The window's top left corner shows, under the
title:

- frames drawn per second (none while nothing changes), the window's size,
  and how much of the window a frame redraws on average;
- the window size;
- GPU time per frame: from submitting the frame to the GPU finishing it
  (`glFinish`, before `eglSwapBuffers` hands the frame to the shell). It
  includes waiting for the shell's compositing on the shared GPU;
- CPU time per frame: recording the frame's draws;
- the pointer's position in the window and the last key pressed;
- the SoC's temperature, the CPU's speed compared with when the demo
  started, and how busy the CPU is. The firmware slows the CPU and GPU when
  the SoC gets hot or the supply voltage sags, so a speed below 100% means
  the Pi, not the software, slowed down. (`config.txt` sets `force_turbo=1`:
  otherwise the firmware drops to its minimum clocks about a minute after
  boot, because Dazzle has no cpufreq driver to ask for more.) The log line every 5 seconds also
  splits the CPU use between the demo and the shell, and the kernel logs
  `Undervoltage detected!` when the supply sags.

The shell also logs, every 5 seconds while it draws, how many frames per
second it composited (with the CPU and GPU time each took) and showed
directly, and how many refreshes went by without a new frame:

```
dazzle-shell: 60.0 frames/s, all shown directly, 0 refreshes skipped
dazzle-shell: work 2.40 ms per frame (clients 0.18, display 1.27 of which commits 1.10, flips 0.30, other 0.60), 3.0 wakeups per frame, 14.4% of the time
```

The second line is the shell's own work, by part: handling clients'
requests, drawing or showing frames
(with the time the kernel takes for the display commits), handling page
flips (frame callbacks and buffer releases), and the rest of the loop.
Display commits only change what differs from the last one: usually just
the primary plane's buffer, with the dock's overlay plane left alone. A
change to the dock alone does not take a refresh while a client
is animating; it goes out with the client's next frame.

Moving a USB mouse moves the cursor. Over the window, each click starts a
small ring: blue for the left button, orange for the right and green for
the middle. The rings grow and fade out.

Below the statistics, Material outlined buttons slow the solid down,
pause it and speed it up. Radio buttons choose the solid (tetrahedron,
cube, octahedron, dodecahedron or icosahedron; its triangle count is
above them), and switches turn the lighting and the checkerboard texture
on and off. In a window too small for it all, the column overflows at the
bottom and shows the stripes.

The statistics change twice a second, and the same statistics go to the
log every 5 seconds. If the solid shows its inside faces rather than its
outside, face culling's winding is reversed. If the font cannot be loaded,
everything but the text is drawn and the log says why.

The serial console on GPIO 14 (TX) and 15 (RX), 115200 baud, still works and
shows the same messages. It is the fallback if the network does not come up.

The firmware picks the Zero, Zero W or Pi 3 A+ device tree in
`config.txt`. Other boards are not supported yet: the Pi 3 B and B+ and
the Zero 2 W have the same SoC as the 3 A+ and would mostly need their
device trees; the Pi 4 and 5 have different GPUs.

On the Pi 3 A+ the CPU figures in the demo are shares of all four cores, so
a program keeping one core busy shows 25%.

### The settings app

Click the gear in the dock (Settings is one of the shell's own apps, in
`/os/shell`). Its window has five pages, chosen with the tabs on the left, with the figures that
change read again every second (`src/settings/info.zig`):

- **System:** the build (git commit, and when it was committed), updates
  (below), Linux's version, how long the system has been up, the board
  (from the device tree, which also tells the chip, CPU and GPU), the
  hostname, and the board's serial number when the firmware gives it.
- **Resources:** how busy the CPU is, the SoC's temperature, memory, the
  GPU's memory (the CMA pool all GPU buffers come from: the V3D has no
  MMU), and storage: a bar of what the system, the apps and the user's
  files take, with a key that ends with the free space. The system and
  apps run from memory (the firmware loads them at boot); the user's
  share and the free space are the SD card's space for files (`/data`),
  once setup has prepared it, or else the memory available. The
  meters turn red above 90%.
- **Ethernet:** each wired adapter's link (and speed), its address
  (and whether it came from DHCP or is static), traffic and MAC
  address, and the default gateway. Under Addressing, choose DHCP or a
  static address: Static opens fields for the address with its prefix
  length (filled in with what DHCP gave) and the gateway (optional), and
  Apply (or Enter) uses it. The choice lasts until the system stops.
- **Wi-Fi:** the adapter, the connection, and the networks around,
  strongest first: their signal, name, security (open, WEP, WPA, WPA2,
  WPA3 or enterprise) and band, each network once (its strongest access
  point). Click a network to join it: a WPA2 network asks for its password
  (type it and press Enter, or Connect). The connection line follows it
  (connecting, checking the password, getting an address, connected with
  the address DHCP gave) and says why if it fails (a wrong password, out of
  range, refused, no answer, or a security not supported yet); Disconnect
  ends it.
- **Apps:** the apps that can be installed, each with its icon, title,
  description, size, and Install or Remove (below).

Everything but Wi-Fi and Ethernet's addressing comes from files any user
can read (`/proc`, `/sys`), so it runs unprivileged like the other apps.
Those need `CAP_NET_ADMIN`, so the app asks init's network manager
(`src/init/network.zig`, with Wi-Fi in `src/init/wifi.zig`) over its socket
(the protocol is `src/sys/network.zig`), which serves only this app; it
scans when asked, at most every 10 seconds (and not while joining), so
nothing scans while the app is closed or covered.

Joining a network: the manager asks the driver to connect to the
network's strongest access point (the chips' firmware associates by
itself). For WPA2, the supplicant (`src/init/supplicant.zig`) then does
the 4-way handshake over EAPOL frames on a packet socket: the passphrase
becomes the pairwise master key (PBKDF2-SHA1 over the SSID), message 1's
nonce and its own make the pairwise keys (the 802.11 PRF), message 2
proves it knows the key (an HMAC-SHA1 MIC), message 3's MIC and RSN
element are checked (a changed element would be a downgrade) and its
group key unwrapped (AES key wrap), and after message 4 the keys go to the
driver over nl80211. Group key updates are handled the same way. A child
process then runs the DHCP client (`src/init/ipv4.zig`) on the interface until
the connection ends; a connection that is lost is tried again. Only CCMP
pairwise keys with PSK key management are supported: WPA2, and mixed
WPA2/WPA3 networks through WPA2. WPA3-only (SAE), enterprise, WPA and WEP
networks are not. The password is kept only in the manager's memory, and
nothing is remembered across a reboot (the system runs from RAM).

The Wi-Fi chips are the Zero W's CYW43430 and the 3 A+'s CYW43455, on the
SDIO bus. The kernel's brcmfmac driver runs them; they need firmware, which
the build downloads from Raspberry Pi OS's `firmware-nonfree` (pinned by
commit and checksum) into the initramfs's `/os/firmware/brcm`, with its
licence (`firmware/LICENCE.cypress`). The driver asks for `brcm/<name>`, so
the files need that directory; `firmware_class.path=/os/firmware` in
`cmdline.txt` has the kernel look for them there rather than in
`/lib/firmware`. The manager talks to the kernel with
nl80211 over generic netlink (`src/init/nl80211.zig`). There is no
regulatory database, so the kernel keeps to the world regulatory domain
and logs that `regulatory.db` is missing.

On the 3 A+, the chip's power (WL_REG_ON) shares a line on the firmware's
GPIO expander with Bluetooth's. Mainline's device tree gives that line to
neither driver, and the firmware leaves it off, so the chip never shows up.
`boot/bcm2837-rpi-3-a-plus.dts` gives it to the Wi-Fi power sequence, as the
Pi 3 B+'s does (there is no Bluetooth driver here to disturb).

### Installing apps

An app is its folder in `/apps` (`/apps/<name>/<name>`, its program, with
`<name>.icon` and its `NOTICES`). The build packs each of its apps
(`build.zig`'s `apps`) as that folder in a tar file (`tools/mkapp.zig`:
the program 0755, everything else 0644), compressed with xz, and writes the
catalogue, `apps.json` (`tools/mkcatalogue.zig`), all in `zig-out/apps`:

```json
{
  "version": "<commit>",
  "apps": [
    {
      "name": "dazzle-demo",
      "title": "Demo",
      "description": "A spinning 3D shape that shows off the graphics, with controls to play with",
      "icon": "view_in_ar",
      "file": "dazzle-demo.tar.xz",
      "size": 92624,
      "sha256": "<the archive's SHA-256, in hex>"
    }
  ]
}
```

CI publishes them beside the image, and the settings app gets them from
there: `https://github.com/robert-ancell/dazzle/releases/latest/download/`
unless built with `-Dapps-url=<url>` (`build_info.apps_url`; an `http://`
URL, such as a local `python3 -m http.server` in `zig-out/apps`, works for
trying it out).

The apps are the user's, so the settings app installs and removes them
itself, without privileges (`src/settings/store.zig`):

- **Where they live:** the first time `/data` is there (on the first start,
  once setup has made it), init copies the boot partition's `apps/` to
  `/data/apps` (written as `apps.new`, then renamed), owned by the user,
  and on every start bind-mounts it at `/apps` (`src/init/apps.zig`).
  Before that, `/apps` is the boot partition's, read-only; the settings
  app does not run then (no app does until setup has finished), so it
  takes `/apps` and `/data/update` to be there.
- **The catalogue** is downloaded when the Apps page is first shown (and
  with Refresh), and kept as `/apps/.catalogue.json`, so the page lists the
  apps without a network. A catalogue that does not parse, or names an
  app that is not a plain folder name (lower-case letters, digits and
  dashes), is refused.
- **Installing** downloads the archive and checks its size and SHA-256
  against the catalogue, then unpacks it into `/apps/.install-<name>`,
  accepting only plain files and folders inside `<name>/` (no links, no
  `..`), and renames the app's folder into place, moving an installed copy
  out of the way first.
- **Removing** renames the folder to `/apps/.remove-<name>`, then deletes
  it.
- Downloads run in a child process (forked), which reports back through a
  pipe, so the window goes on meanwhile, one at a time; one that takes
  more than 10 minutes is stopped. HTTPS is Zig's `std.http.Client` with
  TLS 1.2/1.3, trusting the authorities in `/os/certs/ca-certificates.pem`
  (Mozilla's list, as certifi publishes it; the build pins its version and
  checksum).
- The dock follows `/apps`: the shell looks at its modification time every
  second and lists the apps again when it changes, so an app shows up, or
  goes, as it is installed or removed.

Names and the time, which HTTPS needs, come from the network manager
(`src/init/netconf.zig`): when an interface gets an address it writes the
name servers DHCP gave (or else the gateway) to `/etc/resolv.conf`, where
Zig's resolver looks, and sets the clock once by SNTP from DHCP's time
servers (option 42), or else `pool.ntp.org`, looked up with a small DNS
client of its own. The Pi has no clock that keeps time while it is off, and
certificates are valid only for a while, so until the clock is set
downloads say so. SNTP is not authenticated, so the clock is as
trustworthy as the network; the archives' checksums come from the
catalogue, fetched over HTTPS.

### Updating the system

Each OS slot has a `version` file: when its source was committed (seconds
since 1970) and the commit, as `1791331200 de14aa2`. Newer systems have
later times. The build writes it in slot A, and also packs the slot's
files (all but `cmdline.txt`, which says which slot it is) as an update:
`dazzle-os.tar.xz`, a tar archive of the folder `os` compressed with xz,
and `os.json` describing it (`tools/mkos.zig`; `zig-out/os`):

```json
{
  "version": "de14aa2",
  "time": 1791331200,
  "file": "dazzle-os.tar.xz",
  "size": 4093012,
  "sha256": "<the archive's SHA-256, in hex>"
}
```

CI publishes them beside the image, and the settings app gets them from
there, as it does apps (`src/settings/update.zig`):

- **Checking:** when the System page is first shown (and with Check
  again), it downloads `os.json` to `/data/update` (the user's, made by
  init once `/data` is there). An update is offered when it was committed
  after the running system (the build's own `commit_time`) and is in
  neither slot: the system manager says what each holds, so one already
  installed is not offered again.
- **Downloading:** Download fetches the archive to `/data/update`, checks
  its size and SHA-256 against `os.json`, and asks the system manager to
  install it, giving it the SHA-256 (`update <sha256>`; see
  `sys.system`).
- **Installing** (`src/init/update.zig`): the manager does it in a child
  process, so it goes on answering. The child reads the archive into
  memory and checks its SHA-256 again (the file is the user's: it is
  checked as it is used), makes the boot partition writable, and unpacks
  it into `slot-<x>.new/`, `<x>` being the slot not running. It accepts
  only the folder's plain files and folders, needs a kernel, an initramfs
  and a version, and gives the slot the running slot's command line with
  `dazzle.slot=<x>`. Then the slot that was there (the system before the
  running one) is deleted, `slot-<x>.new/` becomes `slot-<x>/`, and
  `config.txt` is rewritten (as `config.txt.new`, then renamed) with
  `os_prefix=slot-<x>/`, so the firmware starts it next time. The archive
  is then deleted. Until `config.txt` changes, the running system is what
  starts, so a power cut part way leaves the card as it was, at worst
  without the other slot (made again by the next update, or by the
  copier).
- **Restarting:** once the manager says the next start is the other slot,
  Updates offers Restart, which asks the manager to restart (`restart`).
  It keeps `CAP_SYS_BOOT` for this, flushes what is written, and restarts
  through the SoC's watchdog (`CONFIG_BCM2835_WDT`, the board's restart
  handler).

The system manager now runs for as long as the system does (init starts
it at boot, and again if it stops), answering the setup app (`status`,
`prepare`, `finish`) and the settings app (`status`, `update`, `restart`),
each only its own requests. Its report says which slot is running, which
starts next and what each holds.

**Going back** (`src/init/trial.zig`): the Zero's and the 3 A+'s firmware
cannot start a slot just once (`tryboot` is only on the Pi 4 and 5), so
init tries an update itself:

1. Installing writes `/boot/trial`, `<x> pending`, before switching
   `os_prefix` to the updated slot `<x>`.
2. The updated system's init, first thing after mounting `/boot`, marks
   it `<x> started` and switches `os_prefix` back to the other slot: if
   this start fails (it stops, hangs, or the power goes), the next start
   is the system before. Meanwhile a child of init feeds the SoC's
   watchdog (`/dev/watchdog`, 15 s), so a system that hangs restarts by
   itself. The system manager reports the running slot as next, so
   Settings does not offer to restart.
3. Once the shell has run for a minute, the update has worked:
   `os_prefix` names it again, the trial is removed and the watchdog
   stopped. If the shell stops before then, init restarts the Pi, into the
   system before.
4. That system's init finds a trial `started` for the other slot: the
   update did not work. The trial becomes `/boot/trial-failed`, which the
   system manager reports (`update failed did_not_start`) and Settings
   shows; the next install removes it. The failed system stays in its
   slot, so it is not offered again; a newer one is. (A trial still
   `pending` means the power went while installing: it is removed.)

A kernel that does not get as far as init is not caught (`os_prefix`
still names its slot); then it can be changed back by hand on another
computer. Updates are as trustworthy as the HTTPS server they come from:
they are not signed.

### The Files app

Click the folder in the dock. It shows the user's files: `/data`, the SD card's
space for them (Home, at the top of the tree), and nothing above it. The
System files switch at the bottom left shows the whole filesystem instead
(the tree then starts at `/`); turned off again, it goes back home. The
tree of folders is on the left, and the open folder on the right as a grid
of icons (folders, files, programs, devices; links get a badge in one
corner, and folders that cannot be changed a lock in the other), with its
path and an Up button above (Backspace goes up too, as far as the top of
the tree).
Clicking a folder in the tree or the grid opens it, and its row in the
tree comes into view; the arrow beside a folder opens or closes it in
the tree. Clicking a file shows what is in it in place of the grid
(`src/files/viewer.zig`), with what it holds under its path; Up goes back
to its folder. A file is told apart by what it holds, not its name
(`src/files/content.zig`): text is shown a line a row; images (PNG, BMP,
binary PPM and PGM, decoded in `src/files/decode.zig`) as big as they fit;
fonts as samples of their letters at several sizes; anything else as its
bytes, in hexadecimal and as text, as many a row as fit. Only the first
8 MB of a file is read. Clicking a device, pipe or socket only picks it
(opening some devices does things: starting the watchdog, say). The line
under the grid gives the name, kind and size of what is picked. Both sides scroll, with the wheel or by
dragging their bars. Names starting with a dot are left out, a folder
shows at most 1000 entries, and folders are read when they are opened
(`src/files/fs.zig`), as the app's unprivileged user: a folder it may not
read says so.

### Screenshots

Print Screen saves what the screen shows (the dock and the windows; not
the pointer) as `Screenshot 1.png`, `Screenshot 2.png` and so on with the
user's other files, in `/data/user` (the Files app shows them, under
Home): no folder of their own, as the user has few files. The shell
draws the screen again into a buffer of its own and reads it back
(`render.Renderer.capture`), and a child process compresses and writes the
PNG (`src/shell/screenshot.zig`), so the shell goes on drawing meanwhile.
The key does not reach the app with the keyboard.

### The Camera app

The Camera app (`src/camera/`) shows what a Raspberry Pi Camera Module
sees: v1 (OmniVision OV5647) or v2 (Sony IMX219), on the CSI connector.

- **Hardware.** The sensor is controlled over I2C and sends raw frames
  over CSI-2 to the Unicam receiver, which writes them to memory; the
  kernel's drivers (`kernel/dazzle.config`) make them V4L2 devices. Which
  sensor is there cannot be found out by Linux, so the firmware's
  `camera_auto_detect` (in `config.txt`) does: it applies that sensor's
  device tree overlay (`boot/overlays/`, built into each slot's
  `overlays/`). The board device trees (`boot/*.dts`) describe the
  connector's wiring, which differs between the boards, in
  `boot/rpi-camera.dtsi`: the I2C pins (GPIO 28/29 on the Zeros, 44/45 on
  the 3 A+) and the camera's power line (GPIO 41 on the Zero, 44 on the
  Zero W, the firmware's GPIO expander's line 5 on the 3 A+), taken from
  the Raspberry Pi kernel's. The overlays add the sensor (its clock: 24
  MHz for the IMX219, 25 for the OV5647) and turn Unicam's port 1 on.
- **Capture** (`capture.zig`, with the V4L2 structures and ioctls in
  `v4l2.zig`, checked against the kernel's headers for 32-bit ARM and for
  the host): it finds Unicam's video device and the two sub-devices by
  name, flips the sensor for its rotation (the modules are mounted upside
  down), picks the binned full-view mode (1640x1232 on the IMX219,
  1296x972 on the OV5647) and 8-bit samples if the sensor has them (else
  10-bit packed, of which it uses the top 8 bits), sets the format on the
  sensor, Unicam and the video device (they must agree), and streams into
  four buffers mapped into the app.
- **Making pictures** (`isp.zig`): there is no image processor in
  mainline for these boards, so the app does on the CPU what one would.
  Per colour, one 256-entry table takes off the black level (64 of 1023),
  applies the white balance gain and the sRGB gamma. The preview makes a
  pixel of each 2x2 Bayer block (every nth, to fit the window) and
  gathers each colour's mean: the white balance is the grey world (the
  picture's average is grey, eased in over frames). Exposure
  (`exposure.zig`) aims the green mean at mid grey, changing the exposure
  time and then the analogue gain a little every few frames, on the
  IMX219; the OV5647's own automatic exposure and white balance are
  turned on instead.
- **Photos** are the next frame demosaiced at its full size (bilinear),
  compressed and written as the next `Photo N.png` in `/data/user` by a
  child process, so the preview goes on meanwhile.

None of this has been tried on hardware yet. If the camera is not found,
the kernel log says whether the sensor probed (`imx219` or `ov5647`) and
whether Unicam found it.

## How a frame is drawn

1. **Shaders.** Zig compiles each shader program to SPIR-V, and
   `src/shader/` lowers its entry points to the compiler's builder API, as
   a list of SSA values (when Dazzle is built). Three run per draw: a coordinate
   shader the binner uses to find which 64×64 tiles each triangle covers, a
   vertex shader that outputs screen positions and varyings, and a fragment
   shader that writes the pixel colour (and depth) to the tile buffer.
2. **Compilation.** `compiler.zig` removes dead code, folds small constants
   and single-use uniforms into the instructions that read them, allocates
   registers (accumulators and the two register files, preferring the file
   that avoids read port conflicts) and generates QPU code. `qpu_schedule.zig`
   then reorders it with a list scheduler: it respects each result's
   latency, keeps the order of the hardware's FIFO-like ports (uniforms,
   varyings, VPM, texture unit, tile buffer), fills gaps with independent
   work instead of NOPs and pairs add- and mul-ALU operations into one
   instruction. The compiler also records the uniform stream layout,
   including the texture config words the texture unit reads implicitly.
   `qpu.validate` checks the result against the hardware's instruction
   restrictions.

   Fragment shaders that sample textures run two threads per QPU, as
   Mesa's do: after each texture request the QPU switches to the other
   thread while the texture unit fetches, hiding its latency (the last
   switch is marked as the last, so the threads take the tile buffer in
   order). Each thread then has only half of each register file, and
   accumulators do not survive a switch, so values live across one go in
   the register files. The code between switches is scheduled on its own,
   and each switch's signal is fitted into the last instructions before it
   (it takes effect after two delay slots). A shader that needs more
   registers than half compiles single-threaded instead, and the draw's
   shader record says which. In the simulator, the accumulators are filled
   with garbage at each switch, so the tests catch a value kept in one.
3. **Upload.** `DRM_IOCTL_VC4_CREATE_SHADER_BO` uploads each program. The
   kernel validates it, because the V3D has no MMU.
4. **Job.** `render.zig` records a frame: the binning control list (tile binning
   configuration, viewport, clipper and depth state, shader state, a draw
   call), one shader record and the uniform streams. Textures are
   referenced by buffer index so the kernel can relocate and bounds-check
   them.
5. **Submission.** `DRM_IOCTL_VC4_SUBMIT_CL` submits the job. The kernel
   validates it, generates the rendering control list that clears and
   stores each tile (or only those in the job's tile range, when the frame
   is limited to what changed), and runs it on the V3D. The tile buffer is
   stored in the target's format: 32-bit, or RGB565. The shell renders straight into
   a linear XRGB8888 scanout buffer; Wayland clients render into T-tiled
   (RGB565, unless they ask for 32 bits) buffers the shell then draws as
   textures. Depth stays in the on-chip tile
   buffer.
6. **Display.** `display.zig` alternates between two such buffers, flipping
   at vertical blank so animation is tear-free and paced to the refresh
   rate.

### Testing without hardware

- `qpu_sim.zig` runs shaders on a model of the QPU (16 SIMD lanes, VPM,
  varyings, special function unit, texture unit, tile buffer writes). It is
  checked against the hand-written shaders that are known to work on the
  hardware. The tests then check that compiled shaders compute the same
  results, or the results computed on the CPU.
- `vc4/texture.zig`'s tiling, for 32- and 16-bit pixels, is cross-checked
  against a separate implementation of the reference guide's layout
  description in the simulator.
- The shader programs the build compiles are run in the simulator and
  checked against the same maths done on the CPU, and `gfx.preview` draws
  canvases through the real 2D shaders for its pixel tests.
- The Wayland tests run the real server, in a thread with a fake renderer,
  against real clients over a socket pair. One client speaks the protocol
  directly: registry, xdg toplevel and configure, dma-buf and shm buffers,
  frame callbacks, releases, protocol errors, and pointer and keyboard
  focus and events. The other is the demo's path: an `app` window with a
  stand-in GPU, presenting frames and resizing. Both check that everything
  is freed when the client disconnects.
  They pass on the host and as ARM code under `qemu-arm`.

References: Broadcom's *VideoCore IV 3D Architecture Reference Guide*,
`drivers/gpu/drm/vc4/` in the kernel (especially `vc4_validate.c` and
`vc4_validate_shaders.c`) and Mesa's `src/gallium/drivers/vc4/`.

## Status

On a Raspberry Pi Zero the cube, drawn with the `vc4` API, rendered
correctly at a steady 60 fps at 1920x1080 (about 6.5 ms of GPU time per
frame). Compiled shaders, perspective, texturing, depth testing and page
flipping all worked, with the log readable over the network.

The demo is a native app: a window on dazzle-shell, drawn with the `vc4`
API and shaders written in Zig. On a Pi Zero, with the earlier OpenGL version, the
shell showed the demo's buffers directly on the display (no compositing)
at a steady 60 frames per second, with mouse input working. The demo's
`vc4` frames pass a userspace build of the kernel's job and shader
validators; the native version still needs confirming on a Pi.

RGB565 windows (the default) have not been tried on hardware yet: the
simulator and the kernel's checks agree with them, but the texture unit's
order for RGB565 texels comes from Mesa's driver. If restored windows
show red and blue swapped while maximized ones are right, that order is
the other way round (`Format.textureSwapsRedBlue`). Nor has the A8 glyph
atlas: the simulator gives its texels as alpha, as Mesa's driver says the
ALPHA type does (its A8 swizzle is 000W); if text disappears on the Pi,
that is the place to look.

The Pi 3 A+ has not been tried on hardware yet: in QEMU its kernel boots
on the Cortex-A53, and init, the log server and networking work.

In QEMU, as a Zero and as a Pi 3 A+, the kernel boots and init's network
manager gets an address by DHCP over an emulated USB network card. That holds whether the card is there at
boot or added later. The lease renews, and
the log server streams the log (QEMU cannot emulate the
GPU or display).

## Next steps

- Shaders: real branches in the compiler (for loops that depend on the
  data, and skipping blocks no lane takes), discarding fragments,
  integers, `@floor`, and polynomial `sin`/`cos`.
- Mipmaps, more texture formats, and depth buffers stored to memory.
- Add `DRM_IOCTL_VC4_GET_HANG_STATE` reporting for GPU hangs.
- Rendering to textures, and more vertex attribute formats.
- A Vulkan-style API on `vc4`.
- Text: ligatures and other GSUB features, and hinting or stem darkening
  for small sizes.
- The toolkit: more widgets (images, the other Material
  buttons), text selection and non-ASCII typing, keyboard layouts other
  than US, animations, and logical pixels (a scale for the display's
  density).
- Wi-Fi: WPA3 (SAE), remembering networks across reboots (in `/data`),
  and turning a passphrase into a key without holding up the manager.
- Setup: more pages (language, keyboard, network); keeping the Ethernet
  addressing chosen in Settings in `/data`; a way to shut down cleanly.
- Apps: updating installed ones (the catalogue's `version`), signing the
  catalogue, and apps from more than one place.
- Updates: signing them; going back to the other slot from Settings; and
  catching a kernel that does not reach init (the firmware's `tryboot`
  on the Pi 4 and 5).
- The shell: `wl_output`, more than one visible window, blending for
  translucent windows, pointer acceleration, keymaps other than US,
  multi-finger gestures, and kinetic scrolling.
