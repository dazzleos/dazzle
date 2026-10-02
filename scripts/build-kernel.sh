#!/bin/sh
# Build the Stardust kernel (zImage + Pi Zero device trees) from a mainline
# Linux source tree.
#
# Usage: scripts/build-kernel.sh [path/to/linux]
#
# Environment:
#   LINUX_DIR      Linux source tree (default: build/linux, cloned if missing)
#   LINUX_VERSION  Tag to clone if the tree is missing (default: v7.2)
#   CROSS_COMPILE  GCC cross prefix (e.g. arm-linux-gnueabihf-). If unset,
#                  the kernel is built with LLVM (clang + lld).
#   JOBS           Parallel jobs (default: nproc)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINUX_VERSION=${LINUX_VERSION:-v7.2}
LINUX_DIR=${1:-${LINUX_DIR:-$ROOT/build/linux}}
OUT=$ROOT/build/kernel
JOBS=${JOBS:-$(nproc)}

if [ ! -d "$LINUX_DIR" ]; then
	echo "Cloning Linux $LINUX_VERSION into $LINUX_DIR"
	git clone --depth 1 --branch "$LINUX_VERSION" \
		https://github.com/torvalds/linux.git "$LINUX_DIR"
fi

if [ -n "${CROSS_COMPILE:-}" ]; then
	set -- ARCH=arm CROSS_COMPILE="$CROSS_COMPILE"
else
	set -- ARCH=arm LLVM=1
fi

mkdir -p "$OUT"
make -C "$LINUX_DIR" O="$OUT" "$@" tinyconfig
"$LINUX_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT" \
	"$OUT/.config" "$ROOT/kernel/stardust.config"
make -C "$LINUX_DIR" O="$OUT" "$@" olddefconfig

# merge_config only warns when a requested option is dropped because its
# dependencies are unmet. Treat that as fatal: a silently missing driver
# shows up as a black screen on the device.
missing=0
grep '^CONFIG_.*=y$' "$ROOT/kernel/stardust.config" | while IFS= read -r opt; do
	grep -qx "$opt" "$OUT/.config" || { echo "error: $opt not set in final config" >&2; exit 1; }
done || missing=1
[ "$missing" -eq 0 ] || exit 1

make -C "$LINUX_DIR" O="$OUT" "$@" -j"$JOBS" zImage \
	broadcom/bcm2835-rpi-zero.dtb broadcom/bcm2835-rpi-zero-w.dtb

ls -l "$OUT/arch/arm/boot/zImage" "$OUT"/arch/arm/boot/dts/broadcom/bcm2835-rpi-zero*.dtb
