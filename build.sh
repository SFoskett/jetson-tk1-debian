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
# The locale of the person running the build, which is the default locale
# for the image (see local.conf.example). sudo passes LANG through; if it is
# not set, use the build machine's system default.
host_locale="${LANG:-}"
if [ -z "$host_locale" ] && [ -f /etc/default/locale ]; then
	host_locale=$(sed -n 's/^LANG=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' /etc/default/locale | head -1)
fi
export LC_ALL=C.UTF-8

# Host tools needed for the build and for the flashing files.
for tool in mmdebstrap cbootimage fdtput python3 zstd; do
	if ! command -v "$tool" > /dev/null; then
		echo "build.sh: $tool is missing; see the README for the packages to install" >&2
		exit 1
	fi
done

# The build runs ARM programs inside the new system through QEMU, and the
# kernel must load QEMU with binfmt_misc's F (fix binary) flag so it still
# works there. Without the flag, the build fails partway with a confusing
# "failed to run command 'dpkg': No such file or directory".
binfmt=/proc/sys/fs/binfmt_misc/qemu-arm
if ! grep -qx enabled "$binfmt" 2> /dev/null || ! grep -q '^flags:.*F' "$binfmt"; then
	cat >&2 <<EOM
build.sh: ARM emulation is not set up the way the build needs.
QEMU must be registered for ARM programs with the F (fix binary) flag,
shown on the flags line of $binfmt. Currently:
    $(grep -h '^flags' "$binfmt" 2> /dev/null || echo "not registered")
On Ubuntu 24.04, and likely other older releases, install qemu-user-static,
which registers it with the F flag. See the README's requirements.
EOM
	exit 1
fi

# Personal settings for the default user, from local.conf if it exists.
# See local.conf.example. Without it, the image uses tk1/tk1 with SSH off
# until that password is changed at the console.
TK1_USER=tk1
TK1_PASSWORD_HASH=""
TK1_SSH_KEYS=""
TK1_TIMEZONE=UTC
TK1_MDNS=yes
TK1_LOCALE="${host_locale:-C.UTF-8}"
if [ -f "$here/local.conf" ]; then
	. "$here/local.conf"
fi
if ! [[ "$TK1_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
	echo "build.sh: TK1_USER '$TK1_USER' is not a valid username" >&2
	exit 1
fi
if [ "$TK1_MDNS" != yes ] && [ "$TK1_MDNS" != no ]; then
	echo "build.sh: TK1_MDNS must be yes or no" >&2
	exit 1
fi
if ! [[ "$TK1_LOCALE" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
	echo "build.sh: TK1_LOCALE '$TK1_LOCALE' does not look like a locale, for example en_US.UTF-8" >&2
	exit 1
fi
if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$TK1_TIMEZONE" ]; then
	echo "build.sh: TK1_TIMEZONE '$TK1_TIMEZONE' is not a known time zone, for example America/New_York" >&2
	exit 1
fi
if [ -n "$TK1_SSH_KEYS" ] && [ ! -f "$TK1_SSH_KEYS" ]; then
	echo "build.sh: TK1_SSH_KEYS file '$TK1_SSH_KEYS' not found (use a full path, since ~ means root's home under sudo)" >&2
	exit 1
fi

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
	wireless-regdb
	nftables
	unattended-upgrades
	u-boot-tegra
	locales
)

# Refuse to delete a work directory that still has filesystems mounted
# inside it, which an interrupted build can leave behind. Deleting it then
# would reach into the host's /proc, /sys or /dev.
if findmnt -rn -o TARGET | grep -q "^$work/"; then
	echo "build.sh: filesystems are still mounted under $work" >&2
	echo "build.sh: make sure no mmdebstrap is still running, then unmount them with:" >&2
	echo "  findmnt -rn -o TARGET | grep '$rootfs' | sort -r | xargs -r umount" >&2
	exit 1
fi
rm -rf "$work"
mkdir -p "$work"

# Hand the user settings to the customize hook.
{
	printf 'TK1_USER=%q\n' "$TK1_USER"
	printf 'TK1_PASSWORD_HASH=%q\n' "$TK1_PASSWORD_HASH"
	printf 'TK1_TIMEZONE=%q\n' "$TK1_TIMEZONE"
	printf 'TK1_LOCALE=%q\n' "$TK1_LOCALE"
	printf 'TK1_MDNS=%q\n' "$TK1_MDNS"
} > "$work/user.conf"
if [ -n "$TK1_SSH_KEYS" ]; then
	cp "$TK1_SSH_KEYS" "$work/authorized_keys"
fi

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
echo uninitialized > "$rootfs/etc/machine-id"
rm -f "$rootfs/var/lib/dbus/machine-id"

# Make the filesystem image, then shrink it to its minimum size plus a
# small margin for the first boot. The first boot grows it to fill the
# partition, so a smaller image only makes flashing faster.
size_mb=$(( $(du -sm "$rootfs" | cut -f1) * 13 / 10 + 256 ))
rm -f "$img" "$img.zst"
mkfs.ext4 -q -L tk1root -d "$rootfs" "$img" "${size_mb}M"
e2fsck -f -p "$img"
resize2fs -M "$img"
bs=$(dumpe2fs -h "$img" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /, "", $2); print $2}')
blocks=$(dumpe2fs -h "$img" 2>/dev/null | awk -F: '/^Block count/ {gsub(/ /, "", $2); print $2}')
truncate -s $(( (blocks + 64 * 1024 * 1024 / bs) * bs )) "$img"
resize2fs "$img"
e2fsck -f -p "$img"
size_mb=$(( $(stat -c %s "$img") / 1024 / 1024 ))

# Flashing files, built from the U-Boot the customize hook saved and the
# boot configuration in flash/:
#   tk1.bct          memory and boot settings, sent to the board over USB
#   u-boot-flash.bin U-Boot that resets the board's saved U-Boot settings,
#                    exposes the eMMC to the computer over USB, first boot0
#                    and then the main storage, and then resets the board
#   boot0.img        BCT and U-Boot, written to the eMMC's boot0 area
#   u-boot.bin       Debian's unmodified U-Boot, for the manual and L4T
#                    installation methods in docs/
fw="$here/output/flash"
rm -rf "$fw"
mkdir -p "$fw"
bctname=PM375_Hynix_2GB_H5TC4G63AFR_RDA_924MHz
cbootimage -gbct -t124 "$here/flash/$bctname.bct.cfg" "$fw/$bctname.bct"
cp "$work/u-boot-tegra.bin" "$fw/u-boot.bin"
(cd "$fw" && cbootimage -t124 "$here/flash/jetson-tk1-emmc.img.cfg" boot0.img)
mv "$fw/$bctname.bct" "$fw/tk1.bct"

# The flashing U-Boot is Debian's U-Boot with a changed boot command in its
# device tree, which sits at the end of the file. U-Boot reads /config
# bootcmd in place of its normal boot command, and load-environment 0 makes
# it ignore any settings saved on the board. Its first step saves U-Boot's
# default settings over any saved by an earlier U-Boot, in the eMMC's boot1
# area, so leftover settings cannot interfere with the new install.
python3 - "$fw/u-boot.bin" "$work" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
i = data.rfind(b'\xd0\x0d\xfe\xed')
size = int.from_bytes(data[i + 4:i + 8], 'big')
if i < 0 or i + size != len(data):
	sys.exit('build.sh: could not find the device tree at the end of U-Boot')
open(sys.argv[2] + '/uboot-head.bin', 'wb').write(data[:i])
open(sys.argv[2] + '/uboot.dtb', 'wb').write(data[i:])
PY
fdtput -p -t s "$work/uboot.dtb" /config bootcmd "env default -a; env save; ums 0 mmc 0.1; ums 0 mmc 0; reset"
fdtput -t i "$work/uboot.dtb" /config bootdelay 0
fdtput -t i "$work/uboot.dtb" /config load-environment 0
cat "$work/uboot-head.bin" "$work/uboot.dtb" > "$fw/u-boot-flash.bin"

zstd -T0 -q --rm "$img"
(cd "$here/output" && sha256sum "$(basename "$img").zst" > "$(basename "$img").zst.sha256")
rm -rf "$work"

# The build runs as root, so give output/ back to the user who ran sudo.
if [ -n "${SUDO_USER:-}" ]; then
	chown -R "$SUDO_USER": "$here/output"
fi
echo "Built $img.zst (${size_mb}MB uncompressed)"
