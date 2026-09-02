#!/usr/bin/env bash
# Build the kernel-devel equivalent for one WSL2 kernel tag.
#
# Microsoft ships no kernel-headers package for WSL2, so the tree has to be
# built once and pruned to what kbuild needs for an out-of-tree module. The
# result is laid out like a distro kernel-devel package: headers, generated
# config, host tools under scripts/ and tools/, and Module.symvers.
#
# Usage: build.sh <tag> [arch]
#   tag   a microsoft/WSL2-Linux-Kernel tag, e.g. linux-msft-wsl-6.6.123.2
#   arch  x86 (default) or arm64. Native only - no cross toolchain is set up.
set -euo pipefail

TAG="${1:?usage: build.sh <tag> [arch]}"
ARCH="${2:-x86}"
OUT="${OUT:-/wsl-kernel}"
# 1 keeps BTF, which anything using CO-RE eBPF against this kernel needs. Costs
# a much slower, much larger build and requires pahole (dwarves).
BTF="${BTF:-0}"
# 1 runs the real `make modules` instead of reusing vmlinux.symvers. These
# configs carry one to two thousand modules, and an external module only links
# against built-in exports, so the default skips it.
MODULES="${MODULES:-0}"
# 1 keeps drivers/**/*.h - ~500 MB, and only in-tree drivers need them. Kept by
# default so the image works for arbitrary out-of-tree modules, not just ours.
KEEP_DRIVER_HEADERS="${KEEP_DRIVER_HEADERS:-1}"

case "$ARCH" in
	x86)   CONFIG="arch/x86/configs/config-wsl";           IMAGE="bzImage" ;;
	arm64) CONFIG="arch/arm64/configs/config-wsl-arm64";   IMAGE="Image"   ;;
	*) echo "unsupported arch: $ARCH (x86 or arm64)" >&2; exit 1 ;;
esac

HOST_ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo x86)
if [ "$ARCH" != "$HOST_ARCH" ]; then
	echo "arch $ARCH needs a $ARCH host (this one is $HOST_ARCH)" >&2
	exit 1
fi

SRC="$OUT/$TAG-$ARCH"

# Extract aside and move into place: a half-extracted tree poisons every later
# run, because tar leaves a mode-000 placeholder where a symlink will go and
# re-extracting over one fails with EACCES.
if [ ! -f "$SRC/Makefile" ]; then
	rm -rf "$SRC" "$SRC.tmp"
	mkdir -p "$SRC.tmp"
	curl -sfL "https://codeload.github.com/microsoft/WSL2-Linux-Kernel/tar.gz/refs/tags/$TAG" \
		| tar -xz -C "$SRC.tmp" --strip-components=1
	mv "$SRC.tmp" "$SRC"
fi

cp "$SRC/$CONFIG" "$SRC/.config"
if [ "$BTF" != "1" ]; then
	# Debug info is most of the build time and nearly all of the size, and
	# changes neither the symbol CRCs nor vermagic.
	( cd "$SRC" && ./scripts/config \
		-d DEBUG_INFO_BTF \
		-d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -d DEBUG_INFO_DWARF4 -d DEBUG_INFO_DWARF5 \
		-e DEBUG_INFO_NONE )
fi

make -C "$SRC" ARCH="$ARCH" -j"$(nproc)" olddefconfig
make -C "$SRC" ARCH="$ARCH" -j"$(nproc)" modules_prepare
make -C "$SRC" ARCH="$ARCH" -j"$(nproc)" "$IMAGE"

# `make <image>` writes vmlinux.symvers, not Module.symvers - that one comes out
# of the modules modpost pass. An external module only needs the built-in
# exports, which vmlinux.symvers already carries.
if [ "$MODULES" = "1" ]; then
	make -C "$SRC" ARCH="$ARCH" -j"$(nproc)" modules
else
	cp "$SRC/vmlinux.symvers" "$SRC/Module.symvers"
fi
test -f "$SRC/Module.symvers"

RELEASE="$(cat "$SRC/include/config/kernel.release")"
echo "kernel release: $RELEASE"

# --- prune ------------------------------------------------------------------
# Never touch scripts/ or tools/: their host binaries are kept, and kbuild may
# want to re-link them, which needs their sources.
before="$(du -sh "$SRC" | cut -f1)"

find "$SRC" -name '*.o' ! -path "$SRC/scripts/*" ! -path "$SRC/tools/*" -delete
find "$SRC" -name '*.cmd' -delete
rm -rf "$SRC/vmlinux" "$SRC/vmlinux.o" "$SRC/.tmp_vmlinux"* "$SRC/System.map"

find "$SRC" \( -name '*.c' -o -name '*.S' -o -name '*.rs' -o -name '*.dts' -o -name '*.dtsi' \) \
	! -path "$SRC/scripts/*" ! -path "$SRC/tools/*" -delete
rm -rf "$SRC/Documentation" "$SRC/samples"
for d in "$SRC"/arch/*/; do
	[ "$(basename "$d")" = "$ARCH" ] || rm -rf "$d"
done

if [ "$KEEP_DRIVER_HEADERS" != "1" ]; then
	rm -rf "$SRC/drivers"
fi

echo "pruned: $before -> $(du -sh "$SRC" | cut -f1)"
echo "$RELEASE" > "$OUT/kversion"
