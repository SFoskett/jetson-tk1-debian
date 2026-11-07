#!/bin/bash
# Build a Debian trixie root filesystem image for the Jetson TK1.
# Run as root on an x86 host with mmdebstrap, qemu-user-binfmt and zstd.
# The result is output/tk1-trixie-YYYYMMDD.img.zst, an ext4 filesystem
# labeled tk1root, to be written to the APP partition of a TK1's eMMC.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
suite=trixie
mirror=http://deb.debian.org/debian
security=http://security.debian.org/debian-security
stamp=$(date +%Y%m%d)
work="$here/output/work"
rootfs="$work/rootfs"
img="$here/output/tk1-$suite-$stamp.img"

if [ "$(id -u)" -ne 0 ]; then
	echo "build.sh: run as root, for example: sudo $0" >&2
	exit 1
fi
export LC_ALL=C.UTF-8

packages=(
	linux-image-armmp
	initramfs-tools
	u-boot-menu
	device-tree-compiler
	firmware-misc-nonfree
	firmware-realtek
	openssh-server
	sudo
	systemd-resolved
	systemd-timesyncd
	ca-certificates
	zstd
)

rm -rf "$work"
mkdir -p "$work"

# Build the root filesystem. The customize hook runs inside the new
# system, after all packages are installed, to apply the TK1 setup.
mmdebstrap \
	--mode=root \
	--architectures=armhf \
	--keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
	--include="$(IFS=,; echo "${packages[*]}")" \
	--customize-hook="$here/customize.sh \"\$1\"" \
	"$suite" "$rootfs" \
	"deb $mirror $suite main non-free-firmware" \
	"deb $mirror $suite-updates main non-free-firmware" \
	"deb $security $suite-security main non-free-firmware"

# Per-board identity. These are set here rather than in the hook because
# mmdebstrap manages resolv.conf and hostname itself during the build.
echo tk1 > "$rootfs/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\ttk1\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' > "$rootfs/etc/hosts"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
rm -f "$rootfs"/etc/ssh/ssh_host_*
: > "$rootfs/etc/machine-id"
rm -f "$rootfs/var/lib/dbus/machine-id"

# Make the filesystem image with some free space; first boot grows it.
size_mb=$(( $(du -sm "$rootfs" | cut -f1) * 13 / 10 + 256 ))
rm -f "$img" "$img.zst"
mkfs.ext4 -q -L tk1root -d "$rootfs" "$img" "${size_mb}M"
e2fsck -f -p "$img"

zstd -T0 -q --rm "$img"
(cd "$here/output" && sha256sum "$(basename "$img").zst" > "$(basename "$img").zst.sha256")
rm -rf "$work"
echo "Built $img.zst (${size_mb}MB uncompressed)"
