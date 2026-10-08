# Dazzle's architecture

Dazzle is an operating system for the Raspberry Pi 1, 2 and 3, the Zero,
Zero W and Zero 2 W, and the Compute Modules 1 to 3. It is a Linux kernel
and, on top of it, Dazzle's own programs. Everything but the kernel is
written in Zig: init, the shell, the apps, the graphics stack, the widget
toolkit, the font renderer and the build tools. There is no C library:
programs make Linux system calls directly.

[BUILD.md](BUILD.md) says how to build it.

## Components

- **Kernel.** The Raspberry Pi kernel (github.com/raspberrypi/linux),
  the latest commit of its default branch, fetched at every build. It is
  built twice, as Raspberry Pi build it: `kernel.img` (ARMv6) for the Pi 1
  and the Zero and Zero W, and `kernel7.img` (ARMv7, multi-core) for the
  Pi 2, the Pi 3 and the Zero 2 W. Each is `make tinyconfig` plus the
  options in `kernel/`: only what Dazzle uses.
- **Init** (`src/init/`), process 1. It mounts the filesystems, gives the
  user the GPU, and starts the shell. It also runs a few small managers,
  each a child process keeping only the privileges it needs: the network
  (Ethernet, Wi-Fi, DHCP, DNS servers and the clock), devices (giving the
  user input, camera and GPIO devices as they appear), media (mounting USB
  drives as they are plugged in, and ejecting them) and the system
  (setting up the card, the OS slots, updates and restarting), and a log
  server that shows the system's log over HTTP.
- **Shell** (`src/shell/`). The desktop: a Wayland compositor that owns the
  display and the input devices, draws the apps' windows, and has a dock of
  the apps along the bottom of the screen. Apps are Wayland clients that
  connect to it over `/os/sockets/wayland-0`.
- **Apps** (`src/apps/<name>/`). Each is a program with a window, built on
  Dazzle's toolkit. Two are part of the system and installed with it,
  beside the shell: the setup app, run once on the first start, and
  Settings. The others are installed by the user from a catalogue (see
  Apps, below).

The shared code is in modules linked into each program:

| Module | What it is |
|---|---|
| `sys` | System calls, files, and the protocols between the programs and init's managers |
| `vc4` | The GPU: memory, jobs, textures, display (see Rendering) |
| `shader` | Shaders written in Zig, compiled for the GPU |
| `gfx` | 2D drawing on the GPU: shapes and text |
| `font` | OpenType font rendering |
| `icons` | The Material icons Dazzle uses, and a font with just those |
| `ui` | The widget toolkit (see The toolkit) |
| `wayland` | The Wayland protocol, and a client library |
| `app` | An app's window on the shell: buffers, input and the clipboard |
| `store` | Installing and removing apps |
| `locale` | Languages and keyboards: the choice, the keys' characters, and how dates, times and temperatures are written |

Apps use these modules and nothing of each other's or the system's
programs.

## A single-user system

Dazzle has one user, and no accounts, passwords or logins. Init runs as
root; everything else runs as the Dazzle user (uid 1000), the shell and
the apps included. Init's managers start as root and drop to the Dazzle
user, keeping only the capabilities their work needs (configuring the
network, mounting the card and USB drives, writing the card,
restarting). Their sockets are the user's alone, and the network and
system managers answer only the programs entitled to ask (by the
program's path, from the socket's peer credentials).

## The filesystem

The system runs from memory: the firmware loads the kernel and the
initramfs (`initramfs.cpio`) from the SD card, and the initramfs is the
root filesystem. The card's partitions are mounted on it:

```
/os/          Dazzle itself: init, the shell and its built-in apps, the
              font, the Wi-Fi firmware, the trusted certificate authorities,
              and /os/sockets (the shell's and the managers' sockets)
/boot/        the card's boot partition (FAT), read-only: the firmware,
              config.txt and the two OS slots
/data/        the rest of the card (ext4), made on the first start:
  system/     the computer's settings (root's): its name, language and
              keyboard
  user/       the user's files
  apps/       the apps installed, each in apps/<name>/<name>
  update/     where updates are downloaded
/media/       the USB drives plugged in, each in a folder named by its label
/dev /proc /sys
```

The boot partition holds two OS slots, `slot-a/` and `slot-b/`. Each is a
whole system: both kernels, every board's device tree and the overlays,
the initramfs, the kernel command line (which says which slot it is) and a
version file. `config.txt`'s `os_prefix` says which slot the firmware
starts.

## Boot and the first start

1. The Pi's firmware reads `config.txt`, then from the chosen slot the
   kernel for the board's CPU, the board's device tree, the overlays (the
   display driver, and the camera if it finds one) and the initramfs.
2. The kernel runs init from the initramfs (`/os/init`).
3. Init mounts the boot partition, and `/data` if it has been made. It
   names the computer, starts its managers and starts the shell as the
   Dazzle user.

On the first start there is no `/data`. Init grows the boot partition to
its full size, and the shell runs only the setup app, full screen. While
the user names the computer, the system manager gives the rest of the card
a partition, formats it and mounts it at `/data`, and copies slot A to
slot B. The setup app then lists the apps that can be installed, installs
those chosen, and finishes: the computer is named, setup is marked done,
and the dock appears. From then on, the system starts straight to the
desktop.

## Language and keyboard

The language and the keyboard's layout are chosen in setup (its first
page) and in Settings, and kept by the system manager in
`/data/system/locale`. Apps read the language when they start, for their
text and how they write dates, times and temperatures. The shell sends
apps an XKB keymap made from the layout (as Wayland compositors do), and
sends it again when the layout changes; the toolkit maps key codes to
characters by the layout the keymap names.

## GPIO

Settings shows what each GPIO pin is doing, live, by reading the GPIO
registers through `/dev/gpiomem` (mapped read-only, which disturbs no pin,
whatever it is used for). It sets pins up through the kernel's GPIO
character device, which refuses pins a driver has (the console's UART, say):
it asks for a pin, sets it as an input (with a pull up, down or none) or an
output (high or low), and lets it go at once. The Pi's pin driver keeps an
output's level and the pulls after that, so the pin stays so until it is
changed or the Pi restarts, and any app can use the pins in the meantime.

The Data Logger records the pins, read the same way, beside analog inputs
on I2C converters (ADS1115/ADS1015 or PCF8591), registers of I2C devices
(on the header's bus, which config.txt turns on) and serial ports (the
header's UART, and USB adapters). A thread reads every source at the rate
chosen into storage set aside for each, which the window draws as it
fills; a recording is saved as CSV in the user's files.

## Apps

An app is a folder, `/data/apps/<name>/`, with its program (also called
`<name>`), the name of its icon, and its licence notices. The dock shows
every app there, and follows the folder as apps come and go. Apps run as
the Dazzle user, and are started by the shell when their icon is clicked.

An app can say which kinds of files it opens, as MIME types one a line in
`<name>.handles`; it is then started with a file's path as its argument.
Files offers to make and edit text files only if an app opens
`text/plain` (the text editor does), and starts that app to edit them.

An app can ask the shell to open another, showing something
(`/os/sockets/shell`, see `sys.shell`): the Data Logger opens Settings at
its GPIO page. The shell starts the app with it as its argument, or raises
the running app and sends it on to the app's own socket.

Apps are published beside the system image: each as an archive of its
folder (`<name>.tar.xz`), with a catalogue (`apps.json`) giving each one's
title, description, icon, size and SHA-256. The setup app and Settings
download the catalogue and the archives over HTTPS, check them against the
catalogue, unpack them into `/data/apps`, and remove apps by deleting
their folders. No privileges are needed: `/data/apps` is the user's.

## Updates

The build publishes the system as an update too: one slot's files
(`dazzle-os.tar.xz`) and a manifest (`os.json`) with its version, size and
SHA-256. A version is Dazzle's commit and the kernel's, dated by the later
of the two, so a build with a newer kernel is a newer system. Builds are
published on every change and every day, so systems receive the kernel's
latest fixes.

1. Settings downloads the manifest, and offers the update if it is newer
   than the running system and in neither slot.
2. It downloads the archive to `/data/update` and checks it, then asks the
   system manager to install it, giving its SHA-256.
3. The system manager checks the archive again, unpacks it into the slot
   that is not running, marks that slot to be tried, and switches
   `os_prefix` to it. Settings offers to restart.
4. On the next start, init sees the trial and switches `os_prefix` back to
   the previous slot before anything else, and keeps the SoC's watchdog
   running. If the shell runs for a minute, the update has worked: the
   new slot becomes the one started from then on. If the shell stops, or
   the system hangs, the Pi restarts into the previous system, which
   reports that the update did not work. The failed version stays in its
   slot, so it is not offered again.

## Rendering

Dazzle draws with the Raspberry Pi's GPU, the VideoCore IV's 3D engine
(V3D), through the `vc4` module, which talks to the kernel's vc4 driver
directly: there is no OpenGL or Mesa. It allocates GPU buffers, builds the
GPU's control lists (the binning and rendering of a frame in 64×64 tiles),
uploads shader programs and submits jobs with the driver's ioctls; the
kernel checks every job and shader before running it, as the GPU has no
MMU.

Shaders are written in Zig. The build compiles each to SPIR-V, and
Dazzle's own shader compiler (`src/shader/`) turns that into programs for
the GPU's processors (QPUs): register allocation, instruction scheduling
and the GPU's constraints. A simulator of the QPUs and the texture unit
runs the shaders in the host tests.

Each app renders its window with the GPU into buffers it shares with the
shell (as dma-bufs), in the GPU's tiled layout, in 16-bit BGR565 colour
unless it asks for 32 bits (see Memory). The shell draws the windows as
textures into the screen's buffer and shows it with kernel mode setting,
flipping between two buffers at vertical blank. Apps and the shell redraw
only what changed.

## Blocks, the voxel game

Blocks (`src/apps/blocks/`) is a building game in the manner of Minecraft's
creative mode: an island to change a block at a time, from a palette of 36.
It is there to show what the GPU can do, so what it draws is chosen for
what the VideoCore IV does well, and left out where it would not.

- **A small world.** 128 by 128 blocks and 64 high, in 64 chunks of 16 by
  16 (the full height). The sea goes on past the edge to the horizon, as a
  ring of quads that are only water, not blocks. You can see across the
  whole world: fog from 55 blocks out hides where it stops.
- **Few vertices.** Only faces next to something they can be seen through
  are drawn. Neighbouring faces that look the same are merged into one
  quad (greedy meshing), cutting the island to about 38,000 quads. A
  vertex is six floats: the GPU only reads float attributes, so the tile,
  shade, light and how it moves are packed into one float, which the
  vertex shader takes apart. One index buffer serves every quad.
- **Lighting per vertex, not per pixel.** Ambient occlusion darkens
  corners in nooks. Light is smooth across faces: Minecraft-style
  sunlight and lamp light, kept per block and spread when blocks change.
  The sun, sky and fog are worked out per vertex too. The fragment shader
  is a texture read and a multiply-add, because it runs for every pixel.
- **Shading each pixel about once.** Solid blocks are drawn nearest
  first, with the GPU's early depth test on, so what is hidden is not
  shaded. The sky goes after them, only where they left it showing. Its
  sun, moon and stars are per pixel, but only over that part.
- **Water by the vertex, ripples by the pixel.** Waves move the surface's
  vertices, and its colour is worked out per vertex: turquoise in the
  shallows and dark in the deep, the sky reflected more at a glancing
  angle. Over that, a normal map of ripples (`textures.ripples`) is read
  twice, at two sizes drifting different ways, and the sun glints off
  each ripple: the vertex shader works out the half-way vector between
  eye and sun, so the fragment shader needs a dot product and seven
  squarings (84 instructions, where the water lit only per vertex is 32).
  The ripples fade out by 56 blocks away. With N, water is lit per vertex
  only, glint and all. The sea beyond the world's edge is in quads of 1,
  then 4, then 16 blocks, so the per-vertex light changes smoothly.
- **Detailed textures, filtered by the texture unit.** Tiles are 64
  pixels, drawn by code: bevelled bricks, wood grain, cobbles, bark,
  bookshelves. Up close they are filtered smoothly; further off they come
  from mipmaps (`vc4.texture`, laid out as the kernel checks them), so
  they do not shimmer. Mipmaps need the GPU to see how fast the texture
  coordinates change across each 2x2 block of pixels. Wrapping a tile
  inside a merged face in the shader would give it a sudden jump there,
  and so a seam. Instead, the tiles are in strips one tile wide, which the
  texture unit repeats across a face by itself. Faces are merged only
  along that direction (which costs few quads, as light and shade break
  up merges the other way anyway).
- **Bump mapping, with a second texture unit.** Each tile is drawn with a
  height as well as a colour, and from the heights comes a normal map (its
  mipmaps made unit length again). Solid blocks are drawn reading both: the
  colour from texture unit 0 and the normal from unit 1 (`gpu.texture1`,
  binding 2). The vertex shader turns the sun into each face's own frame
  (across the tile, down it, out of the face), so the fragment shader
  needs only a dot product to light every pixel, and the mortar, grain and
  cobbles catch the light and turn with it through the day. The light of
  the sky, lamps and ambient occlusion is still summed per vertex. N
  turns it off, and the tiles are then drawn with their shading baked in.
- **Finer detail up close.** A third texture (`gpu.texture2`) is a patch
  of noise, repeating several times a block, which leans the normal and
  lightens or darkens: grains of sand finer than the tile's texels, wood's
  fibres, the grit of stone (each tile says which: `Tile.detail`, packed
  into its vertices). It shares texture unit 0 with the colour: each
  texture read carries its own config, so a unit can read any number of
  textures (`compiler.Shader.texture` takes a slot; slots alternate
  between the two units, so two reads can be in flight at once). It
  fades out by 12 blocks away.
- **Less work further off.** The bumps fade out by 32 blocks away, where
  the normal maps' mipmaps are nearly flat anyway, and chunks beyond that
  are drawn by the plain terrain shader, with the same plain colours:
  32 fragment shader instructions rather than 79, and half the vertex
  shader. Up close, most of the screen is near chunks, so that is where
  the cost is; the F3 panel shows how many draws are detailed.
- **Only faces that can be seen.** Faces between two solid blocks are
  never made. Chunks behind the eye, or past the fog, are not drawn. Of
  the rest, each chunk's solid faces are kept grouped by the way they
  face (`mesher.face_order`), and a group the eye is behind (all the
  west faces of a chunk east of the eye) is not drawn: about four in ten
  of the solid faces, each saving the coordinate shader and binning. The
  solid blocks are drawn nearest first, so with early-Z a pixel hidden
  behind a nearer one does not run the fragment shader. Chunks hidden
  behind a hill are still drawn (only their pixels are skipped).
- **Antialiased edges, nearly free.** Frames are 4x multisampled
  (`Frame.beginMultisampled`; M turns it off). The tile buffer holds four
  samples a pixel, and they are averaged as each tile is stored. So the
  fragment shaders still run once a pixel, and no more is written to
  memory: what it costs is four times as many tiles (32 pixels square, not
  64) for the GPU to bin and walk through. Shaders that blend read the
  tile buffer to blend with it, and multisampled they must read and write
  each sample in turn, so every program that blends is also compiled that
  way (`Program.fs_ms`), and its pipeline uses it in multisampled frames.
- **Moving things for free.** Leaves and plants sway in the wind in the
  vertex shader. Time of day is a matter of uniforms: sunrise, a red
  sunset, and night with stars and lamps' warm light.
- **One frame.** The GPU keeps depth only within a frame (it is never
  stored), so the whole world is drawn in one. A chunk out of view or
  past the fog is not drawn. The whole island in view is about 170 draws
  and 80,000 triangles.
- **Left out.** There are no shadows, and no flowing water. Leaves are drawn solid
  (cutting holes in a fragment shader is not supported yet). Glass and
  plants are blended, nearest last, but not sorted face by face.

The textures are drawn by code when the game starts (`textures.zig`). The world is made from a
seed: an island with beaches, hills, a snowy mountain, trees and flowers.
It is saved in the user's files (`Island.blocks`), every minute it has
changed and on closing.

Every change to the world goes through one function (`Game.edit`), ready
for a game over the network to send and receive.

The tests draw the island with the real compiled shaders, run in the QPU
simulator (`preview.zig`), so how it looks can be checked without a Pi.

## Memory

The GPU has no MMU, so every buffer it uses (the screen, the windows,
textures, the glyph atlases) must be one piece of physical memory, from
the kernel's contiguous memory allocator (CMA). The device trees reserve
64 MB for it, too little for the shell and a few apps, so `cmdline.txt`
sets `cma=128M`. That leaves about 380 MB for everything else on the
512 MB boards, but only about 128 MB on the 256 MB Pi 1 A and A+. The
system itself is in memory too: the initramfs is about 5 MB.

The size can be changed on Settings' Resources page (64 to 384 MB, no more
than half the computer's memory): more for running many apps at once, less
to leave more for one. Settings asks the system manager, which rewrites
`cma=` in both OS slots' `cmdline.txt` (updates copy the running slot's, so
they keep it); it applies from the next start, and Settings offers to
restart.

Graphics memory is saved where it can be:

- Windows are BGR565, 16 bits a pixel: half the memory of 32-bit colour,
  and half the memory bandwidth to draw them. A full-screen window at
  1920×1080 takes 4 MB a buffer instead of 8 MB. The screen itself stays
  32-bit, as everything is composited into it.
- Text is drawn from a glyph atlas of 8-bit coverage, a quarter of the
  memory of 32-bit colour.
- An app whose window is covered gives back its spare buffers, and one
  that cannot get another buffer makes do with those it has.

## The toolkit

The `ui` module is Dazzle's widget toolkit, used by every app. It is
declarative: an app describes its window as a tree of widgets, built again
from its state whenever something changes. A widget is any Zig struct:
one with a `build` function is made of other widgets, one with a `State`
type keeps that state between frames, and one with `paint`, `layout` or
`event` functions draws, sizes itself or handles input itself.

The toolkit keeps the tree between frames, lays it out (parents give their
children constraints, children choose their sizes), paints it with `gfx`
on the GPU, and delivers pointer, touch and keyboard input. Layout never
fails: whatever overflows is clipped and marked. Only the parts of the
window that changed are painted again.

It has the basic widgets (rows, columns, grids, padding, alignment,
scrolling, lists that make only the items that show), text with its own
OpenType renderer and a glyph atlas on the GPU, Material icons, images,
and controls in Material 3's style: buttons, checkboxes, radio buttons,
switches, text fields with selection and copy and paste, menus, dragging
and dropping, and the title bar each window draws.
