# Dazzle's architecture

Dazzle is an operating system for the Raspberry Pi (1 to 5, Zero, Zero W,
Zero 2 W, and Compute Modules). It consists of the Linux kernel and Dazzle's
own userspace written in Zig: init, the shell, the graphics stack, the
widget toolkit, the font renderer and the build tools. There is no C
library; programs make Linux system calls directly.

[BUILD.md](BUILD.md) explains how to build it.

## Components

- **Kernel.** The Raspberry Pi kernel (`github.com/raspberrypi/linux`), built
  in three configurations from `make tinyconfig` plus the fragments in
  `kernel/`:
  - `kernel.img` (ARMv6) for the Pi 1, Zero and Zero W
  - `kernel7.img` (ARMv7) for the Pi 2, 3, Zero 2 W and 4
  - `kernel8.img` (ARM64) for the Pi 5
- **Init** (`src/init/`), PID 1. It mounts the filesystems, grants the user
  access to the GPU, and starts the shell. It also runs small helper
  managers as child processes, each keeping only the privileges it needs:
  - **network**: Ethernet, Wi-Fi, hotspot, DHCP, DNS and NTP clock sync
  - **devices**: grants access to input, camera and GPIO devices as they appear
  - **media**: mounts and ejects USB drives
  - **system**: partitions the SD card, manages OS slots, installs updates and restarts
  - **logserver**: serves the system log over HTTP
- **Shell** (`src/shell/`). A Wayland compositor that owns the display and
  input devices, composites app windows, and renders the dock at the bottom
  of the screen. Apps connect to it over `/os/sockets/wayland-0`.
- **System apps** (`src/apps/setup/`, `src/apps/settings/`). Built into the
  OS image alongside the shell: Setup runs once on first boot, and Settings
  configures the system. Additional apps can be installed from the app
  catalogue into `/data/apps`.

Shared code lives in modules linked into each program:

| Module | Purpose |
|---|---|
| `sys` | System calls, file helpers, and IPC protocols with init's managers |
| `vc4` | GPU driver interface: memory, jobs, textures and display |
| `shader` | Zig-to-QPU shader compiler |
| `gfx` | 2D GPU rendering for shapes and text |
| `font` | OpenType font rendering |
| `icons` | Material icon subset and generated icon font |
| `ui` | Declarative widget toolkit |
| `wayland` | Wayland wire protocol and client library |
| `app` | Application window setup, buffers, input and clipboard |
| `store` | Installing, updating and removing apps |
| `locale` | Languages, keyboard layouts, and date/time/temperature formatting |
| `video` | Container demuxing, hardware video decoding and playback |

## A single-user system

Dazzle has a single user and no accounts, passwords or logins. Init runs as
root; the shell and all apps run as the Dazzle user (`uid 1000`). Init's
managers start as root and drop to the Dazzle user, retaining only the
Linux capabilities they need. Manager sockets belong to the user, and the
network and system managers verify the caller's executable path via socket
peer credentials (`SO_PEERCRED`).

## The filesystem

The system runs from RAM: the firmware loads the kernel and `initramfs.cpio`
from the SD card as the root filesystem, and mounts the card's partitions on
top:

```
/os/          init, the shell, built-in apps, fonts, Wi-Fi firmware,
              CA certificates, and /os/sockets (Wayland and manager sockets)
/boot/        the card's FAT boot partition (read-only): firmware,
              config.txt, and the two OS slots (slot-a/ and slot-b/)
/data/        the card's ext4 data partition, created on first boot:
  system/     system settings (hostname, locale)
  user/       user files
  apps/       installed apps (/data/apps/<name>/<name>)
  update/     staging directory for OS updates
/media/       mounted USB drives, one directory per drive label
/dev /proc /sys
```

The boot partition contains two complete OS slots (`slot-a/` and `slot-b/`).
Each slot holds the kernels, device trees, overlays, `initramfs.cpio`,
`cmdline.txt` and a version file. `os_prefix` in `config.txt` selects which
slot the firmware boots.

## Boot and first start

1. The Raspberry Pi firmware reads `config.txt` and loads the board's
   kernel, device tree, overlays and `initramfs.cpio` from the active slot.
2. The kernel starts `/os/init` as PID 1.
3. Init mounts `/proc`, `/sys`, `/dev`, `/boot`, and `/data` (if present),
   sets the hostname, starts the managers, and launches the shell.

On the first boot `/data` does not exist yet:

1. Init expands the boot partition entry to its full size and launches the
   shell in setup mode, running only the Setup app full screen.
2. In the background, the system manager creates and formats the `/data`
   partition and populates the second OS slot (`slot-b/`).
3. Once the user confirms the language, keyboard, computer name, optional
   Wi-Fi connection and initial apps, Setup marks setup complete and exits,
   and the shell transitions to the desktop.

## Language and keyboard

The system language and keyboard layout are stored in `/data/system/locale`.
Apps read this file at startup to localize text and format dates, times and
temperatures. The shell generates an XKB keymap for the chosen layout and
sends it to Wayland clients on startup and whenever the layout changes.

## Hardware access

Init's device manager watches for device nodes and grants the Dazzle user
access to:

- **Input devices** (`/dev/input/event*`) for keyboards, mice and touchscreens.
- **Cameras** (`/dev/video*`, `/dev/v4l-subdev*`, `/dev/media*`).
- **GPIO** (`/dev/gpiomem` and `/dev/gpiochip*`) and **I2C / serial**
  (`/dev/i2c-*`, `/dev/ttyAMA*`, `/dev/ttyS*`, `/dev/ttyUSB*`, `/dev/ttyACM*`).

## App packaging and launching

Installed apps live in `/data/apps/<name>/`, which contains the executable,
icon name, licence notices, and an optional `<name>.handles` file listing
supported MIME types (one per line). The dock watches `/data/apps` and
updates automatically as apps are installed or removed.

Apps can ask the shell over `/os/sockets/shell` (`sys.shell`) to launch or
focus another app with an argument.

Apps are distributed as `<name>.tar.xz` archives described by a catalogue
(`apps.json`) containing each app's title, description, icon, size and
SHA-256. Because `/data/apps` is owned by the Dazzle user, installing and
removing apps requires no root privileges.

## OS updates

OS updates are published as `dazzle-os.tar.xz` (the contents of one OS slot)
alongside a manifest (`os.json`) containing the version, size and SHA-256:

1. The update archive is downloaded to `/data/update`, verified against the
   manifest's SHA-256, and passed to the system manager.
2. The system manager verifies the archive again, unpacks it into the
   inactive OS slot, marks that slot for trial, and updates `os_prefix` in
   `config.txt`.
3. On the next boot, init detects the trial, immediately resets `os_prefix`
   back to the previous slot, and starts the hardware watchdog.
4. If the shell runs cleanly for one minute, init commits the new slot by
   switching `os_prefix` back to it and disarming the watchdog. If the shell
   exits early or the system hangs, the board reboots into the previous
   working slot.

## Rendering

Dazzle renders directly on the GPU via the `vc4` module (talking to the
kernel's `vc4` and `v3d` DRM drivers) without OpenGL or Mesa. Shaders are
written in Zig, compiled to SPIR-V at build time, and translated into QPU
machine code by Dazzle's shader compiler (`src/shader/`). A QPU and
texture-unit simulator executes these shaders during host unit tests.

Each app renders its window into tiled GPU buffers shared with the shell as
`dma-buf` file descriptors (16-bit `BGR565` by default, or 32-bit `BGRA8888`
when requested). The shell composites visible windows into the screen
buffer and presents frames via KMS page flips at vertical blank. Both apps
and the shell track damage and redraw only regions that changed.

When a single maximized or fullscreen window covers the screen, the shell
bypasses GPU compositing and scans the app's buffer out directly on the
display hardware (placing the dock on an overlay plane when maximized).

Apps can also request pointer lock (`Window.lockPointer` via the Wayland
pointer-constraints and relative-pointer protocols) and pipelined rendering
(`Window.setPipelined`, keeping one frame in flight on the GPU when enough
CMA memory is free).

## Memory

Display scanout and GPU buffers (window buffers, textures and glyph
atlases) are allocated from the kernel's Contiguous Memory Allocator (CMA).
`cmdline.txt` reserves `cma=128M` by default, and the system manager can
adjust `cma=` across both OS slots (between 64 MB and 384 MB, up to half of
RAM) for the next boot.

To keep GPU memory use low:

- Window buffers default to 16-bit `BGR565` (4 MB instead of 8 MB at
  1920×1080).
- Font glyphs are cached in an 8-bit coverage atlas.
- Covered windows release their spare buffers.
- Triple buffering for pipelined rendering is only allocated when at least
  25% of CMA memory remains free.

## The toolkit

The `ui` module is a declarative widget toolkit. An app describes its window
as a tree of Zig structs rebuilt from application state when state changes:

- Composite widgets implement `build` to return child widgets.
- Stateful widgets declare a `State` type preserved across frames by the
  element tree.
- Leaf widgets implement `layout`, `paint` and `event` to size themselves,
  draw via `gfx`, and handle pointer, touch and keyboard events.

Layout passes constraints down the tree and sizes back up; overflowing
content is clipped rather than failing. Only dirty subtrees are repainted.
The toolkit provides layout containers (rows, columns, grids, scrolling,
lazy lists), OpenType text rendering, Material icons, images, and Material 3
controls (buttons, checkboxes, radio buttons, switches, text fields, menus,
drag-and-drop and window title bars).

