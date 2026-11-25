# Building Dazzle

Dazzle builds on Linux (x86-64 or ARM64).

## Requirements

- `make`, `flex`, `bison`, `bc`, `git`, `curl`, `xz` and the ARM and ARM64
  GCC cross compilers. On Debian or Ubuntu:

  ```sh
  sudo apt install make flex bison bc git curl xz-utils gcc-arm-linux-gnueabihf gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  ```

- Zig 0.17.1. `scripts/zig` downloads it on first use if it is not on your
  PATH.
- Optionally, QEMU and `fdtput`, to boot the system without a Pi
  (`sudo apt install qemu-system-arm device-tree-compiler`).

The build checks for these and names any that are missing.

## Building

```sh
scripts/build
```

This makes `zig-out/dazzle.img`, the SD card image, ready to write to a
card with Raspberry Pi Imager (Use Custom) or `dd`. It also makes the apps
(`zig-out/apps`) and the system as an update (`zig-out/os`), signed with
Ed25519 (`-Dsigning-key=<seed-hex-or-file>` or `DAZZLE_SIGNING_KEY`).

The first build clones the Raspberry Pi kernel into `build/linux-rpi` and
builds it, which takes a while; later builds redo only what changed. Every
build fetches the kernel's latest commit; `-Doffline=true` builds what is
already there.

## Other steps

```sh
scripts/zig build test       # the unit tests, on the build machine
scripts/zig build programs   # just the programs
scripts/zig build kernel     # just the kernels
scripts/zig build serve      # serve zig-out/os and zig-out/apps over HTTPS
                             # (-- --source=motu=../motu/zig-out: and Motu's)
scripts/zig build qemu       # boot in QEMU, as a Pi Zero
```

`scripts/zig build qemu -Dqemu-board=pi3b` boots as another board
(`pi1a+`, `pi2b`, `pi3b` or `pi3a+`). QEMU cannot show the display: it is
for checking the kernel, init and the network, with the log on the serial
console and at `http://localhost:8080/`.

## Testing on a Pi

Options for testing go on the kernel's command line: a slot's
`cmdline.txt` on the card's first partition (`slot-a/` or `slot-b/`, the
one `config.txt`'s `os_prefix` names), on its one line.

- `dazzle.remote=<six digits>`: remote control (`src/shell/remote.zig`) on
  port 8080, with that code.
- `dazzle.log_server=on`: the system's log over HTTP, on port 80.
- `dazzle.setup=again`: setup runs at every start, though it has finished
  (the card's files are kept). Remove it to start to the desktop again.

With remote control on, `/setup` restarts the computer into setup once
(the card's files are kept; finishing it starts the desktop again).
