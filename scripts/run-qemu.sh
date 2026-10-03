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

# Check for the tools up front. The Ubuntu/Debian package providing each
# one follows the colon.
missing_tools=
missing_pkgs=
for entry in qemu-system-arm:qemu-system-arm fdtput:device-tree-compiler; do
	tool=${entry%%:*}
	pkg=${entry#*:}
	if ! command -v "$tool" >/dev/null 2>&1; then
		missing_tools="$missing_tools $tool"
		missing_pkgs="$missing_pkgs $pkg"
	fi
done
if [ -n "$missing_tools" ]; then
	echo "error: missing tools:$missing_tools" >&2
	echo "On Ubuntu/Debian: sudo apt install$missing_pkgs" >&2
	case "$missing_pkgs" in *qemu-system-arm*)
		echo "(On Ubuntu releases with a hardware enablement stack the QEMU package is qemu-system-arm-hwe.)" >&2 ;;
	esac
	exit 1
fi

[ -f "$BOOT/zImage" ] || { echo "Build the kernel first: scripts/build-kernel.sh" >&2; exit 1; }
[ -f "$INITRAMFS" ] || { echo "Build the initramfs first: scripts/zig build" >&2; exit 1; }

cp "$BOOT/dts/broadcom/bcm2835-rpi-zero.dtb" "$DTB"
fdtput -t s "$DTB" /soc/watchdog@7e100000 status disabled

exec qemu-system-arm -M raspi0 \
	-kernel "$BOOT/zImage" \
	-dtb "$DTB" \
	-initrd "$INITRAMFS" \
	-append "console=ttyAMA0 printk.devkmsg=on" \
	-device usb-net,netdev=net0 \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:${LOG_PORT:-2323}-:23 \
	-display none -serial mon:stdio "$@"
