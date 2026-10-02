#!/bin/sh
# Download the closed-source Raspberry Pi boot firmware.
#
# The BCM2835 boots from its VideoCore GPU: bootcode.bin (second stage
# loader), start.elf (GPU firmware) and fixup.dat (memory split) must be on
# the FAT boot partition. They are redistributable but not open source, so
# they are fetched rather than committed.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIRMWARE_TAG=${FIRMWARE_TAG:-1.20260915}
OUT=$ROOT/build/firmware
URL=https://raw.githubusercontent.com/raspberrypi/firmware/$FIRMWARE_TAG/boot

mkdir -p "$OUT"
for f in bootcode.bin start.elf fixup.dat LICENCE.broadcom; do
	if [ ! -f "$OUT/$f" ]; then
		echo "Fetching $f ($FIRMWARE_TAG)"
		curl -fsSL -o "$OUT/$f.tmp" "$URL/$f"
		mv "$OUT/$f.tmp" "$OUT/$f"
	fi
done
