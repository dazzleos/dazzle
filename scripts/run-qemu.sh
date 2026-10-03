#!/bin/sh
# Boot the Stardust kernel and initramfs in QEMU's raspi0 machine.
#
# QEMU does not emulate the V3D, HVS or HDMI blocks, so the triangle is not
# drawn; this checks that the kernel boots, the initramfs unpacks and init
# runs. The init program reports that it cannot find the vc4 device.
#
# QEMU also lacks the BCM2835 power management block, whose driver faults
# while probing. A copy of the device tree with that node disabled is used.
#
# A QEMU USB network card is attached to the Zero's USB port, with QEMU's
# built-in DHCP server. The log server is forwarded to the host:
#
#     telnet localhost 2323

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOT=$ROOT/build/kernel/arch/arm/boot
INITRAMFS=$ROOT/zig-out/initramfs.cpio
DTB=$ROOT/build/qemu-rpi-zero.dtb

[ -f "$BOOT/zImage" ] || { echo "Build the kernel first: scripts/build-kernel.sh" >&2; exit 1; }
[ -f "$INITRAMFS" ] || { echo "Build the initramfs first: scripts/zig build" >&2; exit 1; }

cp "$BOOT/dts/broadcom/bcm2835-rpi-zero.dtb" "$DTB"
fdtput -t s "$DTB" /soc/watchdog@7e100000 status disabled

exec qemu-system-arm -M raspi0 \
	-kernel "$BOOT/zImage" \
	-dtb "$DTB" \
	-initrd "$INITRAMFS" \
	-append "console=ttyAMA0 ip=::::stardust::dhcp printk.devkmsg=on" \
	-device usb-net,netdev=net0 \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:${LOG_PORT:-2323}-:23 \
	-display none -serial mon:stdio "$@"
