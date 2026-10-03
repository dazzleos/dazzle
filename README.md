# Stardust

A lightweight operating system for the Raspberry Pi, written in Zig on top of
a minimal mainline Linux kernel. The first target is the Raspberry Pi Zero /
Zero W (BCM2835).

It has two rendering APIs for the VideoCore IV GPU, both written in Zig on
the kernel's `vc4` driver, so programs can pick the one that suits them:

- **`vc4`**: a low-level API specific to this GPU. Programs build shaders
  with a compiler API and record draw calls into frames themselves.
- **OpenGL ES 2.0 and EGL**: the standard APIs, with GLSL ES 1.00 shaders.
  The entry points use the C ABI under their usual names, so C code can
  call them; Zig code calls the same functions.

On top of them is **stardust-shell**, a minimal Wayland compositor that
draws with the `vc4` API. Init (PID 1, the only process with root
privileges) starts the shell as an unprivileged user, and the shell starts
the demo as its Wayland client. USB mice and keyboards work: the shell
shows a cursor and passes input to the window. The demo shows a spinning,
textured, depth-tested cube drawn with OpenGL ES. Rings spread out and
fade where the pointer clicks. The IP address, rendering
statistics and the last key pressed appear in its top left, in Fira Sans.
A Vulkan-style API may follow.

## Layout

The code is split into Zig modules, linked statically into each program:

| Module | Path | Contents |
|---|---|---|
| `sys` | `src/sys/` | Linux system call helpers (sleeping, clocks, logging, the kernel command line) |
| `vc4` | `src/vc4/` | The low-level graphics API for the VideoCore IV, described below |
| `gles` | `src/gles/` | OpenGL ES 2.0, EGL and the GLSL ES 1.00 compiler, on top of `vc4` |
| `font` | `src/font/` | OpenType font rendering, described below |
| `wayland` | `src/wayland/` | The Wayland wire protocol (with file descriptor passing), the interfaces Stardust uses, and a small client library |
| `stardust-init` | `src/init/` | The init program: mounts, network, log server, device permissions, starting the shell |
| `stardust-shell` | `src/shell/` | The Wayland compositor and shell, described below |
| `stardust-demo` | `src/demo/` | The demo, a Wayland client |

The `vc4` module:

| File | Contents |
|---|---|
| `device.zig` | GPU buffers, shader upload and job submission (`vc4` ioctls) |
| `compiler.zig` | Shader compiler: SSA builder, register allocation and QPU code generation |
| `qpu_schedule.zig` | Instruction scheduler: latency-aware reordering and add/mul pairing |
| `render.zig` | Records a frame: any number of draw calls into one render target, as one job |
| `texture.zig` | Texture tiling (T and LT layouts) and texture unit configuration |
| `display.zig` | Double-buffered scanout with page flips at vertical blank |
| `drm.zig` | DRM core and KMS (mode setting, page flip, cursor) ioctls |
| `cl.zig` | Binning control list packets and shader record layout |
| `qpu.zig` | QPU instruction encoder, hazard checker, instruction pairing and disassembler |
| `qpu_sim.zig` | QPU simulator used by the tests to run shaders on the build machine |
| `reference_shaders.zig` | The original hand-written triangle shaders, known to work on hardware |

The `gles` module:

| File | Contents |
|---|---|
| `gl.zig` | The OpenGL ES 2.0 entry points (exported with the C ABI), types and constants |
| `egl.zig` | EGL 1.4: the display, one configuration, full-screen window surfaces, contexts and `eglSwapBuffers` |
| `context.zig` | GL state and objects, and how draws become `vc4` frames |
| `glsl/` | The GLSL compiler front end, below |

GL covers shaders and programs, buffer objects, float vertex attributes
(from buffers or client memory, and constant values), 2D textures (8-bit
RGBA, RGB, luminance and alpha formats), depth testing, face culling,
viewport, scissor, `glClear`, and `glDrawArrays`/`glDrawElements` with 8-
and 16-bit indices. Rendering is recorded into one `vc4` frame and
submitted by `eglSwapBuffers`. When the app changes a buffer or texture that
frame still uses, it is copied rather than overwritten. Each program is
compiled to QPU code when it is first drawn, once per combination of the
state its hardware shaders depend on (depth testing, and how many
components each attribute supplies). Not yet: blending, stencil,
framebuffer objects, mipmaps, points, `glReadPixels`, and sharing objects
between contexts. Using these records a GL error or logs a warning once.

The GLSL front end (`src/gles/glsl/`):

| File | Contents |
|---|---|
| `lexer.zig` | Tokenizer and a minimal preprocessor (`#version`, `#ifdef GL_ES`, object-like `#define`) |
| `parser.zig` | Parser producing an AST |
| `lower.zig` | Type checking and lowering to the vc4 compiler's SSA builder, one value per scalar component, with constant folding |
| `program.zig` | Compiling shaders and linking programs: uniform slots, attribute locations, varying matching, and deriving the coordinate shader |
| `shader_tests.zig` | Tests: the early demos' shaders written with the builder API, checked in the simulator against the hand-written reference shaders and against GLSL |

Supported so far: `attribute`, `uniform`, `varying` and `const` globals of
float, vector, matrix and `sampler2D` types; `main()` with local variables,
assignments (including to swizzles and matrix columns), arithmetic with
vector and matrix rules, constructors, and the built-ins `texture2D`,
`dot`, `cross`, `length`, `distance`, `normalize`, `min`, `max`, `clamp`,
`mix`, `abs`, `sqrt`, `inversesqrt`, `pow`, `exp`, `log`, `exp2`, `log2`,
`radians` and `degrees`. Not yet: control flow, user functions, arrays,
structs, comparisons and trigonometric functions; these give a compile
error naming the problem.

The `font` module renders text in OpenType fonts with TrueType outlines:

| File | Contents |
|---|---|
| `opentype.zig` | Font parsing: `cmap` (formats 4 and 12), metrics, simple and composite `glyf` outlines, and pair kerning from the GPOS `kern` feature |
| `raster.zig` | Anti-aliased rasterizer: each line adds its exact area coverage to an accumulation buffer, and a running sum gives each pixel's coverage (font-rs's method) |
| `text.zig` | Glyph cache, layout with kerning and quarter-pixel horizontal positioning, and blending into 32-bit pixels |

Glyphs are drawn unhinted with grayscale anti-aliasing. The parser is
bounds-checked throughout, so a damaged font gives errors rather than
crashes. Not supported: CFF outlines, variable font axes, hinting, and
shaping beyond kerning (ligatures, combining marks, right-to-left text).

The apps use **Fira Sans** Regular (`fonts/`, SIL Open Font License 1.1,
from the Google Fonts repository). Its designers made it for Firefox OS,
and it covers Latin, Greek and Cyrillic. The system provides no fonts:
each app has its own copy in its directory, next to the license, and finds
it next to its executable (`sys.appFile`).

The init program (`src/init/`):

| File | Contents |
|---|---|
| `main.zig` | Mounts `/proc`, `/sys`, `/dev`, starts the network manager, log server and device manager, gives the user the GPU, creates its runtime directory, starts the shell and reaps exited processes |
| `devices.zig` | The device manager: gives the user the input devices (`/dev/input/event*`), at start and as uevents announce new ones |
| `network.zig` | The network manager: follows Ethernet adapters and links, configures addresses and routes |
| `dhcp.zig` | DHCP client messages (building requests, parsing replies) |
| `logserver.zig` | Serves the kernel log over HTTP |

The shell (`src/shell/`):

| File | Contents |
|---|---|
| `main.zig` | Opens the GPU and display, listens on `$XDG_RUNTIME_DIR/wayland-0`, starts its clients, and runs the event loop: read input, dispatch clients, then composite a frame when something changed |
| `server.zig` | The Wayland server: clients, objects and requests, frame callbacks and buffer releases, pointer and keyboard focus |
| `render.zig` | Compositing with the `vc4` API: textured quads (shaders written with the builder API) for the bar and the window, the bar's text, and the cursor plane |
| `input.zig` | USB keyboards and mice: finds `/dev/input/event*` nodes and decodes their events |
| `cursor.zig` | The pointer's arrow, drawn into the cursor plane's buffer |
| `server_test.zig` | Protocol tests on the host, described below |

The server offers `wl_compositor`, `wl_shm` (ARGB8888 and XRGB8888, copied
to a texture at commit), `zwp_linux_dmabuf_v1`, `xdg_wm_base` (toplevels)
and `wl_seat` (a pointer and a keyboard). There are no popups or outputs
yet.

- **Windows:** each toplevel is configured to fill the screen below a bar,
  and the newest one is shown. The bar shows the window's title and the
  time since boot.
- **Buffer sharing:** clients render with the GPU straight into buffers
  they share with the shell as dma-bufs, so nothing is copied. The GPU's
  texture unit cannot read ordinary (linear) images, so clients render in
  its T-tiled layout, and the shell draws their buffers as textures. That
  layout is announced with the `BROADCOM_VC4_T_TILED` modifier, as Mesa's
  vc4 driver also does.
- **Pacing:** a frame callback fires once the frame showing it has been
  flipped onto the screen. Buffers are released as soon as a newer one is
  committed, because the shell waits for each composited frame to finish.
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
| `main.zig` | EGL setup on the Wayland platform, the frame loop, input and timing statistics |
| `window.zig` | The Wayland window: an xdg toplevel, its configure events and pings, and the seat's pointer and keyboard |
| `rings.zig` | The rings drawn where the pointer clicks: one triangle strip, coloured on the CPU |
| `cube.zig` | The cube: GLSL shaders, vertex and index buffers, texture, depth testing and culling, written as a C GL program would be |
| `hud.zig` | The statistics overlay: text drawn by the font renderer into a texture, shown as a quad over the top left corner |
| `netinfo.zig` | Looks up the IPv4 address (SIOCGIFCONF, no privileges needed) |

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
  the user ID) and execs `/apps/stardust-shell/stardust-shell`. The shell's stdout and
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
/apps/stardust-shell/       stardust-shell, FiraSans-Regular.ttf and its license
/apps/stardust-demo/        stardust-demo, FiraSans-Regular.ttf and its license
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
- Optional, for the QEMU boot test: `qemu-system-arm` and `fdtput` (`sudo
  apt install qemu-system-arm device-tree-compiler`; on Ubuntu releases with
  a hardware enablement stack the QEMU package is `qemu-system-arm-hwe`).

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
scripts/zig build kernel            # just the kernel
scripts/zig build qemu              # boot in QEMU (arguments after -- go to QEMU)
```

Options: `-Dlinux=path/to/linux` uses an existing kernel tree,
`-Dcross-compile=arm-linux-gnueabihf-` builds the kernel with GCC instead of
LLVM, `-Dimage-size=<MiB>` sets the image size (default 64) and
`-Dhttp-port=<port>` the host port for QEMU's log server (default 8080).

The kernel comes from `make tinyconfig` plus `kernel/stardust.config`. The
build fails if any requested option is dropped because a dependency is
missing. The result is a zImage of about 1.8 MB that includes the vc4 DRM
driver, networking and the USB Ethernet drivers.

## Running on a Pi Zero

Write `zig-out/stardust.img` to an SD card (`dd`, or Raspberry Pi Imager's
"Use custom" option). Alternatively, copy the contents of `zig-out/boot/`
onto any FAT32-formatted card.

Connect HDMI, and a USB Ethernet adapter on the Zero's USB (OTG) port via a
micro-USB OTG adapter, cabled to your network. The kernel has drivers for
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
[    4.740312] stardust: started /apps/stardust-shell/stardust-shell (pid 24) as uid 1000
[    4.741008] stardust: opened /dev/dri/card0 (vc4)
[    4.772511] stardust-shell: build 6ec3896, display <width>x<height>
[    4.772702] stardust-shell: listening on /run/user/1000/wayland-0
[    4.772913] stardust-shell: started /apps/stardust-demo/stardust-demo (pid 25)
[    4.773120] stardust-shell: input: /dev/input/event0: Logitech USB Optical Mouse
[    4.791240] stardust-shell: cursor shown
[    4.790100] stardust-shell: client connected
[    4.802114] stardust: OpenGL ES 2.0 Stardust on VideoCore IV (Stardust), window <width>x<height>
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

The screen shows the shell's bar along the top, and below it the demo's
window. The cube spins at the display's refresh rate. The window's top left
corner shows, after the title, the git commit it was built from (short,
with `-dirty` if there were uncommitted changes), then:

- the IPv4 address, or "No network";
- frames per second and the triangle count;
- the window size;
- GPU time per frame: from submitting the frame to the GPU finishing it
  (`glFinish`, before `eglSwapBuffers` hands the frame to the shell). It
  includes waiting for the shell's compositing on the shared GPU;
- CPU time per frame: issuing the frame's GL calls;
- the pointer's position in the window and the last key pressed;
- the SoC's temperature, the CPU's speed compared with when the demo
  started, and how busy the CPU is. The firmware slows the CPU and GPU when
  the SoC gets hot or the supply voltage sags, so a speed below 100% means
  the Pi, not the software, slowed down. (`config.txt` sets `force_turbo=1`:
  otherwise the firmware drops to its minimum clocks about a minute after
  boot, because Stardust has no cpufreq driver to ask for more.) The log line every 5 seconds also
  splits the CPU use between the demo and the shell, and the kernel logs
  `Undervoltage detected!` when the supply sags.

Moving a USB mouse moves the cursor. Over the window, each click starts a
small ring: blue for the left button, orange for the right and green for
the middle. The rings grow and fade
into the background. (There is no blending yet, so the colour moves
towards the background colour instead.)

The overlay is redrawn twice a second, and the same statistics go to the
log every 5 seconds. If the cube shows its inside faces rather than its
outside, face culling's winding is reversed. If the font cannot be loaded,
the cube is drawn without the overlay and the log says why.

The serial console on GPIO 14 (TX) and 15 (RX), 115200 baud, still works and
shows the same messages. It is the fallback if the network does not come up.

The firmware picks the Zero or Zero W device tree in `config.txt`. The Zero
2 W has a different SoC (BCM2710, ARMv8) and is not supported yet.

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
  `raspi0` machine with an emulated USB network card. `http://localhost:8080/`
  reaches the log server. QEMU does not emulate the 3D engine or HDMI,
  so this checks the kernel, init, privileges and networking only. The log
  ends with `stardust-shell: error: NoVc4Device` and `stardust: shell exited
  with status 1`.

## How a frame is drawn

1. **Shaders.** The GLSL front end (`src/gles/glsl/`) lowers each shader to
   the compiler's builder API, as a list of SSA values. Three run per draw: a coordinate
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
3. **Upload.** `DRM_IOCTL_VC4_CREATE_SHADER_BO` uploads each program. The
   kernel validates it, because the V3D has no MMU.
4. **Job.** `render.zig` records a frame: the binning control list (tile binning
   configuration, viewport, clipper and depth state, shader state, a draw
   call), one shader record and the uniform streams. Textures are
   referenced by buffer index so the kernel can relocate and bounds-check
   them.
5. **Submission.** `DRM_IOCTL_VC4_SUBMIT_CL` submits the job. The kernel
   validates it, generates the rendering control list that clears and
   stores each tile, and runs it on the V3D. The shell renders straight into
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
- Shaders compiled from GLSL are run in the simulator next to the same
  shaders written with the builder API, and must give the same results.
- The GL layer runs against a stand-in GPU backend in the tests, which
  checks the jobs it records and that every GPU buffer and shader it
  creates is freed.
- The Wayland tests run the real server, in a thread with a fake renderer,
  against real clients over a socket pair. One client speaks the protocol
  directly: registry, xdg toplevel and configure, dma-buf and shm buffers,
  frame callbacks, releases, protocol errors, and pointer and keyboard
  focus and events. The other is the demo's
  path: EGL's Wayland platform and the GL layer, swapping and resizing a
  window. Both check that everything is freed when the client disconnects.
  They pass on the host and as ARM code under `qemu-arm`.

References: Broadcom's *VideoCore IV 3D Architecture Reference Guide*,
`drivers/gpu/drm/vc4/` in the kernel (especially `vc4_validate.c` and
`vc4_validate_shaders.c`) and Mesa's `src/gallium/drivers/vc4/`.

## Status

On a Raspberry Pi Zero the cube, drawn with the `vc4` API, rendered
correctly at a steady 60 fps at 1920x1080 (about 6.5 ms of GPU time per
frame). Compiled shaders, perspective, texturing, depth testing and page
flipping all worked, with the log readable over the network.

The demo now draws through OpenGL ES as a Wayland client of
stardust-shell, and neither has run on hardware yet. The shell's
compositing jobs and the demo's T-tiled frames pass a userspace build of the
kernel's job and shader validators. Face culling's winding, sharing buffers
between the processes, and the rendered output still need confirming on a
Pi. The earlier `vc4` API version of the cube is in the git history.

In QEMU the kernel boots and init's network manager gets an address by DHCP
over an emulated USB network card. That holds whether the card is there at
boot or added later. The lease renews, a static `stardust.ip=` works, and
the log server streams the log (QEMU cannot emulate the
GPU or display).

## Next steps

- GLSL: control flow (needs branches in the compiler), user functions,
  arrays, and polynomial `sin`/`cos`.
- Mipmaps, more texture formats, and depth buffers stored to memory.
- Add `DRM_IOCTL_VC4_GET_HANG_STATE` reporting for GPU hangs.
- GL: blending (in the fragment shader, reading the tile buffer),
  framebuffer objects, and more vertex attribute formats.
- A Vulkan-style API on `vc4`.
- Text: ligatures and other GSUB features, hinting or stem darkening for
  small sizes, and text drawn by the GPU (a glyph atlas texture, once
  blending is supported).
- The shell: `wl_output`, more than one visible window, blending for
  translucent windows, pointer acceleration, keymaps (XKB) and key repeat,
  and touch screens.
