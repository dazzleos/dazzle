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

# Check for the build tools up front, so a missing one is reported clearly
# instead of as an error partway through the kernel build. The Ubuntu/Debian
# package providing each tool is listed after the colon.
tools="make:make flex:flex bison:bison bc:bc"
[ -d "$LINUX_DIR" ] || tools="$tools git:git"
if [ -n "${CROSS_COMPILE:-}" ]; then
	tools="$tools ${CROSS_COMPILE}gcc:gcc-arm-linux-gnueabihf ${CROSS_COMPILE}ld:binutils-arm-linux-gnueabihf"
else
	tools="$tools clang:clang ld.lld:lld llvm-ar:llvm llvm-nm:llvm llvm-objcopy:llvm llvm-objdump:llvm llvm-readelf:llvm llvm-strip:llvm"
fi
missing_tools=
missing_pkgs=
missing_llvm=
for entry in $tools; do
	tool=${entry%%:*}
	pkg=${entry#*:}
	if ! command -v "$tool" >/dev/null 2>&1; then
		missing_tools="$missing_tools $tool"
		case $pkg in clang | lld | llvm) missing_llvm=1 ;; esac
		case " $missing_pkgs " in *" $pkg "*) ;; *) missing_pkgs="$missing_pkgs $pkg" ;; esac
	fi
done
if [ -n "$missing_tools" ]; then
	echo "error: missing build tools:$missing_tools" >&2
	echo "On Ubuntu/Debian: sudo apt install$missing_pkgs" >&2
	[ -z "$missing_llvm" ] || echo "Or set CROSS_COMPILE to build with a GCC cross compiler instead of LLVM." >&2
	exit 1
fi

# Linux v7.2 needs LLVM 17.0.1 or newer (scripts/min-tool-version.sh).
if [ -z "${CROSS_COMPILE:-}" ]; then
	clang_major=$(clang -dumpversion | cut -d. -f1)
	if [ "$clang_major" -lt 17 ]; then
		echo "error: clang $(clang -dumpversion) is too old; the kernel needs LLVM 17 or newer." >&2
		echo "Install a newer clang, lld and llvm (e.g. apt install clang-18 lld-18 llvm-18 and add" >&2
		echo "/usr/lib/llvm-18/bin to PATH), or set CROSS_COMPILE to use GCC." >&2
		exit 1
	fi
fi

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
