# Stardust

A lightweight operating system for the Raspberry Pi, written in Zig on top of
a minimal mainline Linux kernel. It runs on the Raspberry Pi Zero / Zero W
(BCM2835) and the Raspberry Pi 3 A+ (BCM2837), from the same SD card image.

Stardust is its own stack. Everything draws with **`vc4`**, a low-level
API for the VideoCore IV GPU written in Zig on the kernel's `vc4` driver:
programs record draw calls into frames themselves, with shaders written in
Zig, compiled by Zig to SPIR-V and from that to the GPU's code when
Stardust is built. There is no OpenGL layer: the one Stardust had, for porting existing
apps, is in the git history if it is needed again.

On top of it is **stardust-shell**, a minimal Wayland compositor. Init (PID 1, the only process with root
privileges) starts the shell as an unprivileged user. Its dock along the
bottom of the screen has an icon for each app; clicking one starts the app
as a Wayland client, or brings its window to the front if it is already
running. USB mice and keyboards work: the shell shows a cursor and passes
input to the window. The demo, a native app built
with Stardust's widget toolkit, shows a spinning, depth-tested Platonic
solid, with Material 3 buttons to change its speed, radio buttons to
choose the solid and switches to turn its lighting and texture on and
off. Rings spread out and fade
where the pointer clicks. The IP address, rendering
statistics and the last key pressed appear in its top left, in Fira Sans.
The settings app shows the build, the hardware, how much CPU, memory, GPU
memory and storage is in use, and the network's status. A Vulkan-style
API may follow.

## Layout

The code is split into Zig modules, linked statically into each program:

| Module | Path | Contents |
|---|---|---|
| `sys` | `src/sys/` | Linux system call helpers (sleeping, clocks, logging, the kernel command line) |
| `vc4` | `src/vc4/` | The low-level graphics API for the VideoCore IV, described below |
| `shader` | `src/shader/` | Shaders written in Zig: SPIR-V translated to `vc4` programs, and pipelines for drawing with them |
| `app` | `src/app/` | Native apps' windows on stardust-shell: buffers shared with the shell, frame pacing and input |
| `gfx` | `src/gfx/` | 2D graphics for the toolkit: anti-aliased rounded rectangles, circles, polygons and polylines, filled or stroked, and text, blended |
| `ui` | `src/ui/` | The widget toolkit: declarative widgets with state, layout, painting and input, in Material 3's style |
| `font` | `src/font/` | OpenType font rendering, described below |
| `wayland` | `src/wayland/` | The Wayland wire protocol (with file descriptor passing), the interfaces Stardust uses, and a small client library |
| `stardust-init` | `src/init/` | The init program: mounts, network, log server, device permissions, starting the shell |
| `stardust-shell` | `src/shell/` | The Wayland compositor and shell, described below |
| `stardust-demo` | `src/demo/` | The demo, a native app |
| `stardust-settings` | `src/settings/` | The settings app: the build, the hardware, what is in use and the network |

The `vc4` module:

| File | Contents |
|---|---|
| `device.zig` | GPU buffers, shader upload and job submission (`vc4` ioctls) |
| `compiler.zig` | Shader compiler: SSA builder, register allocation and QPU code generation, with threaded fragment shaders |
| `qpu_schedule.zig` | Instruction scheduler: latency-aware reordering and add/mul pairing |
| `render.zig` | Records a frame: any number of draw calls into one render target, as one job |
| `texture.zig` | Texture tiling (T and LT layouts) and texture unit configuration |
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
| `atlas.zig` | `Atlas`: glyphs rasterized by the font renderer, packed into one texture, and the text runs laid out recently |
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
kept while it is drawn each frame.

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
| `widgets.zig` | `Row`, `Column`, `Expanded`, `Padding`, `Align`, `Center`, `SizedBox`, `ConstrainedBox`, `Overlay`, `Decorated` (a filled or outlined rounded rectangle) and `Pressable` (clicks, hover and press) |
| `text.zig` | `Text`: lines at `\n`, wrapped at spaces to fit |
| `material.zig` | Material 3's light and dark baseline themes, and `OutlinedButton`, made of a `Pressable`, `Decorated`, `ConstrainedBox`, `Padding` and `Center` |
| `controls.zig` | Material 3's selection controls: `Checkbox`, `Radio` (generic over the value it selects) and `Switch` (its handle slides), each with an optional label that presses it too |
| `painter.zig` | Painting: canvas layers and GPU draws in order, clipping, and the overflow stripes |
| `damage.zig` | What changed between frames: each node's drawing fingerprinted and compared, kept as a few rectangles, with a history for buffers of any age |
| `runtime.zig` | `Ui`: builds, lays out and paints each frame, records it into a `vc4` frame (or draws it on the CPU, for tests), and sends pointer events to the widgets under the pointer |
| `tests.zig` | Tests: overflow, nonsense layouts, state and keys, buttons, overlays, GPU draws' order, rows and columns, controls, damage |

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
under something that changes. The glyph atlas and the shell's bar (an
overlay plane, redrawn once a second) are the retained buffers there are.
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
the result. Shaders are static, so this costs nothing when Stardust runs,
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
| `main.zig` | Opens the GPU and display, listens on `$XDG_RUNTIME_DIR/wayland-0`, and runs the event loop: read input (clicks on the dock start or raise apps), dispatch clients, then composite a frame when something changed |
| `server.zig` | The Wayland server: clients, objects and requests, frame callbacks and buffer releases, pointer and keyboard focus |
| `render.zig` | Compositing with the `vc4` API: textured quads for the panels (the bar and the dock) and the window, the bar's text, and the cursor plane |
| `dock.zig` | The dock: finds the apps in `/apps`, draws their icons, and finds the one clicked |
| `shaders/quad.zig` | The textured quad's shader |
| `input.zig` | USB keyboards and mice: finds `/dev/input/event*` nodes and decodes their events |
| `cursor.zig` | The pointer's arrow, drawn into the cursor plane's buffer |
| `server_test.zig` | Protocol tests on the host, described below |

The server offers `wl_compositor`, `wl_shm` (ARGB8888 and XRGB8888, copied
to a texture at commit), `zwp_linux_dmabuf_v1`, `xdg_wm_base` (toplevels)
and `wl_seat` (a pointer and a keyboard). There are no popups or outputs
yet.

- **Windows:** each toplevel is configured to fill the screen between the
  bar and the dock, and the newest one is shown, or the one whose app was
  last clicked in the dock. The bar shows the window's title and the time
  since boot.
- **Covered windows:** the windows behind the front one cannot be seen, so
  they are told: they get xdg_toplevel's `suspended` state (xdg-shell
  version 6) instead of `activated`, their frame callbacks are held until
  they are in front again, and what they commit meanwhile does not make
  the shell draw a frame. Stardust's apps then stop drawing (the demo's
  solid stops spinning) and free the buffers they are not using, so the
  app in front has the GPU memory; raised, they draw again.
- **GPU memory:** every buffer the GPU touches comes from the kernel's CMA
  pool (the V3D has no MMU). At 1080p the shell's two screen buffers take
  17 MB and each window up to three 7 MB buffers, more than the device
  tree's 64 MB pool leaves once the kernel's binner memory is taken, so
  `cmdline.txt` sets `cma=128M`. An app that cannot get another buffer
  makes do with those it has, or waits for memory to be freed.
- **Apps:** each directory in `/apps` holding a program of the same name
  (`/apps/<name>/<name>`) is an app, with an icon in the dock: its initial
  on a coloured square, with a dot under it while it runs. Apps run once
  each: the shell knows each client's process (from its socket), and
  clicking a running app raises its window. Nothing starts until it is
  clicked, other than programs named on the shell's command line.
- **Buffer sharing:** clients render with the GPU straight into buffers
  they share with the shell as dma-bufs, so nothing is copied. The GPU's
  texture unit cannot read ordinary (linear) images, so clients render in
  its T-tiled layout, and the shell draws their buffers as textures. That
  layout is announced with the `BROADCOM_VC4_T_TILED` modifier, as Mesa's
  vc4 driver also does.
- **Direct scanout:** the display hardware can scan out T-tiled buffers
  and stack several planes. When the shown window's buffer is exactly the
  work area's size (as a maximized window's is), the shell puts it on the
  display's primary plane as it is, and the bar and the dock on overlay
  planes above it, with one atomic commit. Nothing is composited, which saves the GPU a
  full-screen copy and a third of the memory traffic per frame. Otherwise
  (other sizes, shm buffers, or a driver without atomic mode setting) the
  shell composites the frame with the GPU as before.
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
  is over it, in window coordinates. There is no XKB keymap: the keymap
  format is `no_keymap`, so key events carry Linux key codes, and key
  repeat is off. Clients' own cursor images (`set_cursor`) are ignored.
  Devices plugged in later are found within a second.

The demo program (`src/demo/`):

| File | Contents |
|---|---|
| `main.zig` | The window (from the `app` module), the frame loop, input and timing statistics |
| `view.zig` | The window's widgets: the rings and the solid behind a column with the statistics, the speed buttons, the radio buttons choosing the solid, and the lighting and texture switches |
| `rings.zig` | The rings drawn where the pointer clicks: stroked circles on the 2D canvas, fading out |
| `solids.zig` | The five Platonic solids: meshes found from their corners (with flat normals, a tint per face and a checkerboard across each), drawn with depth testing and culling, lit and textured or not |
| `netinfo.zig` | Looks up the IPv4 address (SIOCGIFCONF, no privileges needed) |
| `shaders/` | The solids' shader: tint, optional lighting (diffuse from a fixed light, with ambient) and optional texture |

### Privileges

Only init runs as root. Everything else runs as the Stardust user: the
fixed user and group ID 1000 (`sys.user`). There are no accounts,
passwords or logins.

- Once vc4 has probed, init makes the DRM nodes in `/dev/dri` owned by that
  user, mode 0660. The shell is the first to open the card, so it becomes
  DRM master and can set modes and flip pages without privileges. Clients
  use the render node (`/dev/dri/renderD128`), which can render but not
  touch the display.
- Init creates `/run/user/1000` (the user's runtime directory, mode 0700),
  forks, drops to the user (no supplementary groups, then the group, then
  the user ID) and execs `/shell/stardust-shell`. The shell's stdout and
  stderr are init's `/dev/kmsg` descriptor, because only root can open that
  for writing. The shell's clients inherit them.
- The network manager runs as the same user but keeps three capabilities:
  configuring interfaces and routes (`CAP_NET_ADMIN`), tying its DHCP
  socket to the interface (`CAP_NET_RAW`) and binding the DHCP client port
  (`CAP_NET_BIND_SERVICE`). Init restarts it if it ever stops.
- The device manager runs as the user, keeping only `CAP_CHOWN`. Input
  device nodes are created owned by root, so it gives each one to the user
  (at start, then on each uevent that adds one), and the shell can read
  them. Init restarts it if it ever stops.
- The log server binds port 80 as root, then drops to the same user. Reading
  `/dev/kmsg` needs no privileges.
- Init logs how the shell exits, and the shell logs how its clients exit.
  Neither is restarted.

This needs `CONFIG_MULTIUSER` in the kernel (about 8 KB). Without it, every
process has every privilege.

Also: `build.zig` (the whole build, see below), `tools/` (host tools the
build runs: `mkinitramfs.zig` packs the initramfs, `mkimage.zig` writes the
SD card image, `check.zig` checks for build tools, the kernel
configuration and firmware checksums), `kernel/stardust.config` (kernel
config fragment applied on top of `tinyconfig`), `boot/` (firmware
`config.txt` and kernel `cmdline.txt`) and `scripts/zig` (downloads Zig).

The image's filesystem (an initramfs, in RAM) is kept simple:

```
/init                       stardust-init
/shell/                     stardust-shell, FiraSans-Regular.ttf and its license
/apps/stardust-demo/        stardust-demo, FiraSans-Regular.ttf and its license
/apps/stardust-settings/    stardust-settings, FiraSans-Regular.ttf and its license
/dev /proc /sys /run        mounted or created by init
```

There is no C library: programs make raw system calls through
`std.os.linux`.

## Requirements

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

## Building

One command builds everything into an SD card image:

```sh
scripts/zig build    # zig-out/stardust.img, and its files in zig-out/boot/
```

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
LLVM, `-Dimage-size=<MiB>` sets the image size (default 64) and
`-Dhttp-port=<port>` the host port for QEMU's log server (default 8080).

The kernel comes from `make tinyconfig` plus `kernel/stardust.config`. The
build fails if any requested option is dropped because a dependency is
missing. The result is a zImage of about 2 MB that includes the vc4 DRM
driver, networking and the USB Ethernet drivers.

One 32-bit kernel serves both boards: it is built for ARMv6 (the Zero's
ARM1176) and ARMv7 (the Pi 3 A+'s Cortex-A53, which the firmware starts
in AArch32), with SMP for the A+'s four cores (on the Zero's single core
the SMP-only instructions are patched out at boot). The programs are
ARMv6 code, which the A53 runs as it is. The firmware picks each board's
device tree (`config.txt`).

## Running on a Pi Zero or Pi 3 A+

Write `zig-out/stardust.img` to an SD card (`dd`, or Raspberry Pi Imager's
"Use custom" option). Alternatively, copy the contents of `zig-out/boot/`
onto any FAT32-formatted card. The same card works in either board.

Connect HDMI, and a USB Ethernet adapter cabled to your network: on the
Zero's USB (OTG) port via a micro-USB OTG adapter, or in the Pi 3 A+'s USB
port (with a hub for the keyboard and mouse). Neither board's Wi-Fi works
yet. The kernel has drivers for
common adapter chipsets: Realtek RTL8152/8153, ASIX AX88772/AX88179, SMSC
LAN95xx, Microchip LAN78xx and generic CDC Ethernet.

### Reading the log over the network

The network never holds up boot. Init starts a network manager alongside
everything else. It waits for an Ethernet adapter and a link, gets an
address by DHCP and keeps renewing the lease. The adapter can be plugged in
or out, and the cable connected, at any time. A log server also starts
before the GPU is touched, so the log stays readable if a GPU job hangs.
The Pi asks the DHCP server for the hostname `stardust`, so look for that
name in your router's lease list, then open `http://<pi-address>/` in a
browser (or `curl http://<pi-address>/`). It shows the whole log since
boot: kernel, init and program messages. `http://<pi-address>/follow`
shows the same, then new messages as they arrive (`curl -N` follows it in a
terminal). The port can be changed with `stardust.httpport=<port>` in
`cmdline.txt`.

```
Stardust 6ec3896 system log. /follow shows new messages as they arrive.

[    4.731220] stardust: starting as init (build 6ec3896)
[    4.739512] stardust: log server listening on HTTP port 80 as uid 1000
[    4.740011] stardust: network: found eth0 (<mac>)
[    4.746230] stardust: network: eth0 link up
[    4.940117] stardust: network: eth0 is 192.168.1.42/24, gateway 192.168.1.1 (DHCP, lease 86400 s)
[    4.740312] stardust: started /shell/stardust-shell (pid 24) as uid 1000
[    4.741008] stardust: opened /dev/dri/card0 (vc4)
[    4.772511] stardust-shell: build 6ec3896, display <width>x<height>
[    4.772610] stardust-shell: app Demo (/apps/stardust-demo/stardust-demo)
[    4.772702] stardust-shell: listening on /run/user/1000/wayland-0
[    4.773120] stardust-shell: input: /dev/input/event0: Logitech USB Optical Mouse
[    4.791240] stardust-shell: cursor shown
[    7.312913] stardust-shell: started /apps/stardust-demo/stardust-demo (pid 25)
[    7.330100] stardust-shell: client connected
[    4.802114] stardust: drawing with the vc4 API, window <width>x<height>
[    9.840211] stardust: 60.0 fps, GPU <t> ms, CPU <t> ms per frame
```

Timestamps above are illustrative, and the order varies because the network
comes up in parallel with the demo. To use a static address instead of DHCP,
add `stardust.ip=<address>/<prefix>[,<gateway>]` to `cmdline.txt`, for
example:

```
stardust.ip=192.168.1.50/24,192.168.1.1
```

### The demo

The screen shows the shell's bar along the top and its dock along the
bottom; click the demo's icon in the dock to start it, and its window
fills the space between them. The solid spins at the display's refresh rate. The window's top left
corner shows, after the title, the git commit it was built from (short,
with `-dirty` if there were uncommitted changes), then:

- the IPv4 address, or "No network";
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
  boot, because Stardust has no cpufreq driver to ask for more.) The log line every 5 seconds also
  splits the CPU use between the demo and the shell, and the kernel logs
  `Undervoltage detected!` when the supply sags.

The shell also logs, every 5 seconds while it draws, how many frames per
second it composited (with the CPU and GPU time each took) and showed
directly, and how many refreshes went by without a new frame:

```
stardust-shell: 60.0 frames/s, all shown directly, 0 refreshes skipped
stardust-shell: work 2.40 ms per frame (clients 0.18, bar 0.04, display 1.27 of which commits 1.10, flips 0.30, other 0.60), 3.0 wakeups per frame, 14.4% of the time
```

The second line is the shell's own work, by part: handling clients'
requests, redrawing the bar (once a second), drawing or showing frames
(with the time the kernel takes for the display commits), handling page
flips (frame callbacks and buffer releases), and the rest of the loop.
Display commits only change what differs from the last one: usually just
the primary plane's buffer, with the bar's overlay plane left alone. A change to the bar alone does not take a refresh while a client
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

Click "S" in the dock. Its window has four cards, with the figures that
change read again every second (`src/settings/info.zig`):

- **System:** the build (git commit), Linux's version and how long the
  system has been up.
- **Hardware:** the board (from the device tree), the chip, the CPU's core
  and how many there are, the GPU (the V3D's version, QPUs and slices,
  from the vc4 driver), the memory, and the board's revision and serial
  number.
- **In use:** how busy the CPU is, the SoC's temperature, memory, the GPU's
  memory (the CMA pool all GPU buffers come from: the V3D has no MMU), and
  the system's files. Stardust has no driver for the SD card: the firmware
  loads the system into memory at boot and it runs from there, so its
  storage is that filesystem in RAM. The meters turn red above 90%.
- **Network:** the hostname, each adapter's link (and speed), its address
  (and whether it came from DHCP or `stardust.ip=`), traffic and hardware
  address, and the default gateway.

Everything comes from files any user can read (`/proc`, `/sys`) and the
GPU's render node, so it runs unprivileged like the other apps.

## Faster development loops

- **Raspberry Pi OS:** `zig-out/bin/stardust-shell` and `stardust-demo`
  also run as normal programs on Raspberry Pi OS (Lite, or with the desktop stopped) on any Pi
  from the Zero to the Pi 3. All of them have the same VideoCore IV and
  `vc4` driver. From a text console, as a user in the `video` and `input`
  groups, run the shell with `XDG_RUNTIME_DIR` set:
  `stardust-shell path/to/stardust-demo`. Each program looks for
  `FiraSans-Regular.ttf` next to its executable, so copy
  `fonts/FiraSans-Regular.ttf` there (`stardust-demo` also takes a font
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
  so this checks the kernel, init, privileges and networking only. The log
  ends with `stardust-shell: error: NoVc4Device` and `stardust: shell exited
  with status 1`.

## How a frame is drawn

1. **Shaders.** Zig compiles each shader program to SPIR-V, and
   `src/shader/` lowers its entry points to the compiler's builder API, as
   a list of SSA values (when Stardust is built). Three run per draw: a coordinate
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
   is limited to what changed), and runs it on the V3D. The shell renders straight into
   a linear XRGB8888 scanout buffer; Wayland clients render into T-tiled
   buffers the shell then draws as textures. Depth stays in the on-chip tile
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
- `vc4/texture.zig`'s tiling is cross-checked against a separate
  implementation of the reference guide's layout description in the
  simulator.
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

The demo is a native app: a window on stardust-shell, drawn with the `vc4`
API and shaders written in Zig. On a Pi Zero, with the earlier OpenGL version, the
shell showed the demo's buffers directly on the display (no compositing)
at a steady 60 frames per second, with mouse input working. The demo's
`vc4` frames pass a userspace build of the kernel's job and shader
validators; the native version still needs confirming on a Pi.

The Pi 3 A+ has not been tried on hardware yet: in QEMU its kernel boots
on the Cortex-A53, and init, the log server and networking work.

In QEMU, as a Zero and as a Pi 3 A+, the kernel boots and init's network
manager gets an address by DHCP over an emulated USB network card. That holds whether the card is there at
boot or added later. The lease renews, a static `stardust.ip=` works, and
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
- The toolkit: more widgets (scrolling, text fields, images, the other
  Material buttons), keyboard focus, animations, and logical pixels (a
  scale for the display's density).
- The shell: `wl_output`, more than one visible window, blending for
  translucent windows, pointer acceleration, keymaps (XKB) and key repeat,
  and touch screens.
