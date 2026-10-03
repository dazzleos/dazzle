# Stardust

A lightweight operating system for the Raspberry Pi, written in Zig on top of
a minimal mainline Linux kernel. The first target is the Raspberry Pi Zero /
Zero W (BCM2835).

The long-term plan is an OpenGL ES 2.0 library that drives the VideoCore IV
GPU through the kernel's `vc4` driver, and a simple Wayland shell on top of
it. Today it is a single program, run as PID 1, that compiles its own GPU
shaders and draws with the GPU by talking to `vc4` directly: a spinning,
textured, depth-tested cube by default.

## Layout

The code is split into Zig modules, linked statically into each program:

| Module | Path | Contents |
|---|---|---|
| `sys` | `src/sys/` | Linux system call helpers (sleeping, clocks, logging, the kernel command line) |
| `vc4` | `src/vc4/` | The low-level graphics API for the VideoCore IV, described below |
| `stardust-init` | `src/init/` | The init program: mounts, log server and the demos |

The `vc4` module:

| File | Contents |
|---|---|
| `device.zig` | GPU buffers, shader upload and job submission (`vc4` ioctls) |
| `compiler.zig` | Shader compiler: SSA builder, register allocation and QPU code generation |
| `qpu_schedule.zig` | Instruction scheduler: latency-aware reordering and add/mul pairing |
| `render.zig` | Builds a job (control list, shader record, uniform streams) for one draw call |
| `texture.zig` | Texture tiling (T and LT layouts) and texture unit configuration |
| `display.zig` | Double-buffered scanout with page flips at vertical blank |
| `drm.zig` | DRM core and KMS (mode setting, page flip) ioctls |
| `cl.zig` | Binning control list packets and shader record layout |
| `qpu.zig` | QPU instruction encoder, hazard checker, instruction pairing and disassembler |
| `qpu_sim.zig` | QPU simulator used by the tests to run shaders on the build machine |
| `reference_shaders.zig` | The original hand-written triangle shaders, known to work on hardware |

The init program (`src/init/`):

| File | Contents |
|---|---|
| `main.zig` | Mounts `/proc`, `/sys`, `/dev`, starts the log server, sets up the display and runs a demo |
| `logserver.zig` | Serves the kernel and init log over TCP (telnet) |
| `demos.zig` | The demo scenes: `triangle`, `spin` and `cube` |
| `programs.zig` | The demos' shaders, written with the compiler's builder API |

Also: `tools/mkinitramfs.zig` (packs the init binary into a cpio
initramfs), `kernel/stardust.config` (kernel config fragment applied on top
of `tinyconfig`), `boot/` (firmware `config.txt` and kernel `cmdline.txt`)
and `scripts/` (kernel build, firmware download, SD image, QEMU and Zig).

There is no C library: programs make raw system calls through
`std.os.linux`.

## Requirements

- Zig 0.16.0. `scripts/zig` downloads it into `build/zig/` on first use
  (checked against the SHA-256 in ziglang.org's release index) unless a
  `zig` 0.16.0 is already on your PATH, so installing Zig is optional.
- To build the kernel: `make`, `flex`, `bison`, `bc`, `git`, and either
  LLVM 17 or newer (used by default; `sudo apt install clang lld llvm`) or
  an ARM GCC cross compiler (set `CROSS_COMPILE=arm-linux-gnueabihf-`).
  `scripts/build-kernel.sh` checks for these and names any missing packages.
- To build the SD image: `sfdisk` (fdisk), `mkfs.vfat` (dosfstools),
  `mcopy` (mtools) and `curl` (`sudo apt install fdisk dosfstools mtools
  curl`). `scripts/build-image.sh` checks for these too.
- Optional: `qemu-system-arm` and `fdtput` (device-tree-compiler) for the
  QEMU boot test

## Building

```sh
scripts/zig build test             # host unit tests
scripts/zig build --release=small  # zig-out/bin/stardust-init and zig-out/initramfs.cpio
scripts/build-kernel.sh            # clones Linux v7.2 into build/linux on first run
scripts/build-image.sh             # build/boot/ and build/stardust.img
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
readable if a GPU job hangs. The Pi asks the DHCP server for the hostname
`stardust`, so look for that name in your router's lease list, then:

```sh
telnet <pi-address>    # or: nc <pi-address> 23
```

The telnet session prints the whole log since boot (kernel and init
messages) and then follows new messages:

```
[    4.731220] stardust: starting as init
[    4.739512] stardust: log server listening on TCP port 23
[    4.741008] stardust: opened /dev/dri/card0 (vc4)
[    4.741903] stardust: V3D revision <rev>, <n> slices of <n> QPUs
[    4.802114] stardust: output connector <id> on crtc <id>: <mode> <width>x<height>@<hz>
[    4.802600] stardust: demo cube (choose with stardust.demo=triangle|spin|cube)
[    4.811875] stardust: shaders compiled and uploaded
[    4.833540] stardust: displaying cube
[    9.840211] stardust: 300 frames in 5.0s (60.0 fps), render <t> ms/frame
```

Timestamps above are illustrative. To use a static address instead of DHCP,
replace `ip=::::stardust::dhcp` in `cmdline.txt` with, for example:

```
ip=192.168.1.50::192.168.1.1:255.255.255.0:stardust::off
```

If no adapter is plugged in, boot waits about 12 seconds for one before
continuing without a network. With an adapter but no cable, it waits 10
seconds for a link (`carrier_timeout=10`).

### Choosing a demo

`stardust.demo=` in `cmdline.txt` selects what is drawn:

| Demo | What it shows |
|---|---|
| `triangle` | The original hand-written shaders, drawn once |
| `spin` | A triangle rotating at the display's refresh rate, drawn with compiled shaders and double buffering |
| `cube` (default) | A spinning cube with perspective, a checkerboard texture tinted per face, and depth testing |

Each builds on the previous one, so if one fails on the hardware the
simpler ones narrow down where. The animated demos log their frame rate and
render time every 5 seconds.

The serial console on GPIO 14 (TX) and 15 (RX), 115200 baud, still works and
shows the same messages. It is the fallback if the network does not come up.

The firmware picks the Zero or Zero W device tree in `config.txt`. The Zero
2 W has a different SoC (BCM2710, ARMv8) and is not supported yet.

## Faster development loops

- **Raspberry Pi OS:** `zig-out/bin/stardust-init` also runs as a normal
  program on Raspberry Pi OS (Lite, or with the desktop stopped) on any Pi
  from the Zero to the Pi 3. All of them have the same VideoCore IV and
  `vc4` driver. Run it as root from a text console. It runs the cube demo
  for 10 seconds and exits. Iterating on GPU code this way avoids rebuilding the
  SD card.
- **QEMU:** `scripts/run-qemu.sh` boots the kernel and initramfs in QEMU's
  `raspi0` machine with an emulated USB network card. `telnet localhost
  2323` reaches the log server. QEMU does not emulate the 3D engine or HDMI,
  so this checks the kernel, init and networking only. The log ends with
  `stardust: error: NoVc4Device`.

## How a frame is drawn

1. **Shaders.** `src/init/programs.zig` describes each shader with the compiler's
   builder API, as a list of SSA values. Three run per draw: a coordinate
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
4. **Job.** `render.zig` writes the binning control list (tile binning
   configuration, viewport, clipper and depth state, shader state, a draw
   call), one shader record and the uniform streams. Textures are
   referenced by buffer index so the kernel can relocate and bounds-check
   them.
5. **Submission.** `DRM_IOCTL_VC4_SUBMIT_CL` submits the job. The kernel
   validates it, generates the rendering control list that clears and
   stores each tile, and runs it on the V3D. Rendering goes straight into a
   linear XRGB8888 buffer; depth stays in the on-chip tile buffer.
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

References: Broadcom's *VideoCore IV 3D Architecture Reference Guide*,
`drivers/gpu/drm/vc4/` in the kernel (especially `vc4_validate.c` and
`vc4_validate_shaders.c`) and Mesa's `src/gallium/drivers/vc4/`.

## Status

On a Raspberry Pi Zero the cube demo renders correctly at a steady 60 fps
at 1920x1080 (about 6.5 ms of GPU time per frame): compiled shaders,
perspective, texturing, depth testing and page flipping all work, with the
log readable over the network.

In QEMU the kernel boots, the network comes up by DHCP over an emulated USB
network card and the log server streams the log (QEMU cannot emulate the
GPU or display).

## Next steps

- Compiler: a GLSL ES 1.00 front end, then control flow.
- Mipmaps, more texture formats, and depth buffers stored to memory.
- Add `DRM_IOCTL_VC4_GET_HANG_STATE` reporting for GPU hangs.
- Split the GL work into a library with a GLES 2.0 / EGL API and a separate
  test program.
- Input (evdev) and a Wayland compositor.
