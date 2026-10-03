# Stardust

A lightweight operating system for the Raspberry Pi, written in Zig on top of
a minimal mainline Linux kernel. The first target is the Raspberry Pi Zero /
Zero W (BCM2835).

The long-term plan is an OpenGL ES 2.0 library that drives the VideoCore IV
GPU through the kernel's `vc4` driver, and a simple Wayland shell on top of
it. This first milestone is a single program, run as PID 1, that compiles
its own GPU shaders and draws a triangle by talking to `vc4` directly.

## Layout

| Path | Contents |
|---|---|
| `src/main.zig` | Init program: mounts `/proc`, `/sys`, `/dev`, finds the display, draws, keeps the image on screen |
| `src/logserver.zig` | Serves the kernel and init log over TCP (telnet) and announces the Pi's address |
| `src/qpu.zig` | QPU (shader processor) instruction encoder, hazard checker and disassembler |
| `src/shaders.zig` | Coordinate, vertex and fragment shaders for the triangle, generated with `qpu.zig` |
| `src/vc4/cl.zig` | Binning control list packets and shader record layout |
| `src/vc4.zig` | `vc4` ioctls: buffers, shader upload, job submission |
| `src/drm.zig` | DRM core and KMS (mode setting) ioctls |
| `src/triangle.zig` | Builds and submits the draw job |
| `tools/mkinitramfs.zig` | Host tool that packs the init binary into a cpio initramfs |
| `kernel/stardust.config` | Kernel config fragment applied on top of `tinyconfig` |
| `boot/` | Firmware `config.txt` and kernel `cmdline.txt` |
| `scripts/` | Kernel build, firmware download, SD image and QEMU scripts |

There is no C library and no other userspace: the init program makes raw
system calls through `std.os.linux`.

## Requirements

- Zig 0.16.0
- To build the kernel: `make`, `flex`, `bison`, `bc` and either LLVM/Clang
  (18 or newer, used by default) or an ARM GCC cross compiler (set
  `CROSS_COMPILE=arm-linux-gnueabihf-`)
- To build the SD image: `sfdisk` (util-linux), `mkfs.vfat` (dosfstools),
  `mcopy` (mtools), `curl`
- Optional: `qemu-system-arm` and `fdtput` (device-tree-compiler) for the
  QEMU boot test

## Building

```sh
zig build test                 # host unit tests
zig build --release=small      # zig-out/bin/stardust-init and zig-out/initramfs.cpio
scripts/build-kernel.sh        # clones Linux v7.2 into build/linux on first run
scripts/build-image.sh         # build/boot/ and build/stardust.img
```

`scripts/build-kernel.sh path/to/linux` uses an existing kernel tree instead.

The kernel comes from `make tinyconfig` plus `kernel/stardust.config`. The
script fails if any requested option is dropped because a dependency is
missing. The result is a zImage of about 1.8 MB that includes the vc4 DRM
driver, networking and the USB Ethernet drivers.

## Running on a Pi Zero

Write `build/stardust.img` to an SD card (`dd`, or Raspberry Pi Imager's
"Use custom" option). Alternatively, copy the contents of `build/boot/` onto
any FAT32-formatted card.

Connect HDMI, and a USB Ethernet adapter on the Zero's USB (OTG) port via a
micro-USB OTG adapter, cabled to your network. The kernel has drivers for
common adapter chipsets: Realtek RTL8152/8153, ASIX AX88772/AX88179, SMSC
LAN95xx, Microchip LAN78xx and generic CDC Ethernet.

### Reading the log over the network

The kernel gets an address by DHCP during boot (`ip=` in `boot/cmdline.txt`).
Init then starts a log server before touching the GPU, so the log stays
readable if a GPU job hangs. On your computer:

```sh
nc -ul 5555            # wait for the Pi to announce its address
telnet <pi-address>    # or: nc <pi-address> 23
```

The announcement is one line, `stardust <pi-address> 23`, sent once at boot
to the host and port in `stardust.announce=` in `cmdline.txt` (currently
192.168.1.83:5555). The Pi also asks the DHCP server for the hostname
`stardust`, so it may show up under that name in your router's lease list.

The telnet session prints the whole log since boot (kernel and init
messages) and then follows new messages:

```
[    4.731220] stardust: starting as init
[    4.739512] stardust: log server listening on TCP port 23
[    4.741008] stardust: opened /dev/dri/card0 (vc4)
[    4.741903] stardust: V3D revision <rev>, <n> slices of <n> QPUs
[    4.802114] stardust: output connector <id> on crtc <id>: <mode> <width>x<height>@<hz>
[    4.811875] stardust: rendered frame
[    4.833540] stardust: displaying triangle
```

Timestamps above are illustrative. To use a static address instead of DHCP,
replace `ip=::::stardust::dhcp` in `cmdline.txt` with, for example:

```
ip=192.168.1.50::192.168.1.1:255.255.255.0:stardust::off
```

If no adapter is plugged in, boot waits about 12 seconds for one before
continuing without a network. With an adapter but no cable, it waits 10
seconds for a link (`carrier_timeout=10`).

The serial console on GPIO 14 (TX) and 15 (RX), 115200 baud, still works and
shows the same messages. It is the fallback if the network does not come up.

The firmware picks the Zero or Zero W device tree in `config.txt`. The Zero
2 W has a different SoC (BCM2710, ARMv8) and is not supported yet.

## Faster development loops

- **Raspberry Pi OS:** `zig-out/bin/stardust-init` also runs as a normal
  program on Raspberry Pi OS (Lite, or with the desktop stopped) on any Pi
  from the Zero to the Pi 3. All of them have the same VideoCore IV and
  `vc4` driver. Run it as root from a text console. It shows the triangle for
  10 seconds and exits. Iterating on GPU code this way avoids rebuilding the
  SD card.
- **QEMU:** `scripts/run-qemu.sh` boots the kernel and initramfs in QEMU's
  `raspi0` machine with an emulated USB network card. `telnet localhost
  2323` reaches the log server. QEMU does not emulate the 3D engine or HDMI,
  so this checks the kernel, init and networking only. The log ends with
  `stardust: error: NoVc4Device`.

## How the triangle is drawn

1. `shaders.zig` generates three QPU programs:
   - a coordinate shader, run by the binner to find which 64×64 tiles the
     triangle covers
   - a vertex shader, which outputs screen positions and the colour varyings
   - a fragment shader, which interpolates the colour and writes it to the
     tile buffer

   `qpu.validate` checks them against the hardware's instruction
   restrictions.
2. `DRM_IOCTL_VC4_CREATE_SHADER_BO` uploads each program. The kernel
   validates it, because the V3D has no MMU.
3. `triangle.zig` writes the binning control list (tile binning
   configuration, viewport and clipper state, shader state, a draw call), one
   shader record and the uniform streams.
4. `DRM_IOCTL_VC4_SUBMIT_CL` submits the job. The kernel validates the job,
   generates the rendering control list that clears and stores each tile, and
   runs it on the V3D. Rendering goes straight into a linear XRGB8888 buffer.
5. The same buffer becomes a KMS framebuffer and is shown with a legacy mode
   set.

References: Broadcom's *VideoCore IV 3D Architecture Reference Guide*,
`drivers/gpu/drm/vc4/` in the kernel (especially `vc4_validate.c` and
`vc4_validate_shaders.c`) and Mesa's `src/gallium/drivers/vc4/`.

## Status

The kernel builds and boots in QEMU, and the init program runs as PID 1.
In QEMU the network comes up by DHCP over an emulated USB network card, the
address announcement arrives and the log server streams the log.
The GPU path has not run on hardware yet. Its shaders and the complete
submitted job have been checked offline against the kernel's own
`vc4_validate_shaders.c` and `vc4_validate.c`, which accept them. Whether
the hardware draws the expected image still needs a real Pi Zero.

## Next steps

- Confirm the triangle on hardware; add `DRM_IOCTL_VC4_GET_HANG_STATE`
  reporting for GPU hangs.
- Replace the hand-written shaders with a compiler: an SSA IR, register
  allocation and instruction scheduling for the QPU, then a GLSL ES 1.00
  front end.
- Depth buffers, textures (T-format tiling), double buffering with page
  flips.
- Split the GL work into a library with a GLES 2.0 / EGL API and a separate
  test program.
- Input (evdev) and a Wayland compositor.
