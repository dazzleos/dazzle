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
  user input and camera devices as they appear) and the system (setting up
  the card, the OS slots, updates and restarting), and a log server that
  shows the system's log over HTTP.
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

Apps use these modules and nothing of each other's or the system's
programs.

## A single-user system

Dazzle has one user, and no accounts, passwords or logins. Init runs as
root; everything else runs as the Dazzle user (uid 1000), the shell and
the apps included. Init's managers start as root and drop to the Dazzle
user, keeping only the capabilities their work needs (configuring the
network, mounting and writing the card, restarting), and answer only the
programs entitled to ask (by the program's path, from the socket's peer
credentials).

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
  system/     the computer's settings (root's)
  user/       the user's files
  apps/       the apps installed, each in apps/<name>/<name>
  update/     where updates are downloaded
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

## Apps

An app is a folder, `/data/apps/<name>/`, with its program (also called
`<name>`), the name of its icon, and its licence notices. The dock shows
every app there, and follows the folder as apps come and go. Apps run as
the Dazzle user, and are started by the shell when their icon is clicked.

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
shell (as dma-bufs), in the GPU's tiled layout, usually as 16-bit colour
to save memory. The shell draws the windows as textures into the screen's
buffer and shows it with kernel mode setting, flipping between two
buffers at vertical blank. Apps and the shell redraw only what changed.

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
switches, text fields with selection and copy and paste, menus and the
title bar each window draws.
