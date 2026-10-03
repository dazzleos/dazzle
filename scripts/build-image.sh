#!/bin/sh
# Assemble the boot files and an SD card image.
#
# Outputs:
#   build/boot/        files to copy onto a FAT32-formatted SD card
#   build/stardust.img a complete SD card image (write with dd or
#                      Raspberry Pi Imager's "Use custom" option)
#
# Requires: the kernel (scripts/build-kernel.sh), the initramfs (scripts/zig build),
# and sfdisk, mkfs.vfat (dosfstools) and mcopy (mtools) for the image.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KBOOT=$ROOT/build/kernel/arch/arm/boot
BOOT=$ROOT/build/boot
IMG=$ROOT/build/stardust.img
IMG_MB=${IMG_MB:-64}

# sfdisk and mkfs.vfat live in /usr/sbin, which is not always on a normal
# user's PATH. Neither needs root when working on an image file.
PATH=$PATH:/usr/sbin:/sbin

# Check for the image tools up front. The Ubuntu/Debian package providing
# each tool is listed after the colon.
missing_tools=
missing_pkgs=
for entry in sfdisk:fdisk mkfs.vfat:dosfstools mcopy:mtools curl:curl truncate:coreutils; do
	tool=${entry%%:*}
	pkg=${entry#*:}
	if ! command -v "$tool" >/dev/null 2>&1; then
		missing_tools="$missing_tools $tool"
		case " $missing_pkgs " in *" $pkg "*) ;; *) missing_pkgs="$missing_pkgs $pkg" ;; esac
	fi
done
if [ -n "$missing_tools" ]; then
	echo "error: missing tools:$missing_tools" >&2
	echo "On Ubuntu/Debian: sudo apt install$missing_pkgs" >&2
	exit 1
fi

"$ROOT/scripts/fetch-firmware.sh"

[ -f "$KBOOT/zImage" ] || { echo "Build the kernel first: scripts/build-kernel.sh" >&2; exit 1; }
[ -f "$ROOT/zig-out/initramfs.cpio" ] || { echo "Build the initramfs first: scripts/zig build" >&2; exit 1; }

rm -rf "$BOOT"
mkdir -p "$BOOT"
cp "$ROOT"/build/firmware/bootcode.bin "$ROOT"/build/firmware/start.elf \
	"$ROOT"/build/firmware/fixup.dat "$ROOT"/build/firmware/LICENCE.broadcom "$BOOT/"
cp "$KBOOT/zImage" "$KBOOT"/dts/broadcom/bcm2835-rpi-zero.dtb \
	"$KBOOT"/dts/broadcom/bcm2835-rpi-zero-w.dtb "$BOOT/"
cp "$ROOT/zig-out/initramfs.cpio" "$ROOT/boot/config.txt" "$ROOT/boot/cmdline.txt" "$BOOT/"

# One FAT32 partition starting at 1 MiB.
part_start=2048
part_sectors=$(( (IMG_MB - 1) * 2048 ))
rm -f "$IMG" "$IMG.boot"
truncate -s "${IMG_MB}M" "$IMG"
echo "start=$part_start, size=$part_sectors, type=c, bootable" | sfdisk --quiet "$IMG"
mkfs.vfat -F 32 -n STARDUST -C "$IMG.boot" $(( part_sectors / 2 )) >/dev/null
mcopy -i "$IMG.boot" "$BOOT"/* ::/
dd if="$IMG.boot" of="$IMG" bs=512 seek=$part_start conv=notrunc status=none
rm -f "$IMG.boot"

du -sh "$BOOT"
ls -l "$IMG"
