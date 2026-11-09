#!/bin/bash
# Flash a Jetson TK1 with open-source tools only. The board must be in
# recovery mode and connected by its micro-USB port. This writes U-Boot to
# the eMMC's boot0 area, replaces the main storage with a single tk1root
# partition, and writes the root filesystem image into it.
#
# Usage: sudo ./flash-tk1.sh [image]
# The image defaults to the newest output/tk1-*.img.zst from build.sh.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fw="$here/output/flash"
boot0_size=4194304

die() { echo "flash-tk1.sh: $*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
	die "run as root, for example: sudo $0"
fi
for tool in tegrarcm lsusb lsblk sgdisk partprobe udevadm zstd eject dd; do
	command -v "$tool" > /dev/null || die "$tool is missing; see the README for the packages to install"
done

img="${1:-$(ls -t "$here"/output/tk1-*.img.zst 2>/dev/null | head -1)}"
[ -n "$img" ] && [ -f "$img" ] || die "no image found; run build.sh first or give the image path"
for f in tk1.bct u-boot-flash.bin boot0.img; do
	[ -f "$fw/$f" ] || die "$fw/$f is missing; run build.sh first"
done
echo "Image: $img"

# Find the disk U-Boot exposes over USB. Only a USB disk that identifies
# itself as U-Boot's mass storage device ("Linux UMS disk") is considered,
# and its size must match what is expected, so no other disk is touched.
find_ums_disk() {
	local want="$1" name size tran vendor model
	while read -r name size tran vendor model; do
		[ "$tran" = usb ] || continue
		[ "$vendor" = Linux ] || continue
		case "$model" in "UMS disk"*) ;; *) continue ;; esac
		if [ "$want" = boot0 ] && [ "$size" = "$boot0_size" ]; then
			echo "$name"; return 0
		fi
		if [ "$want" = main ] && [ "$size" -gt $((1024 * 1024 * 1024)) ]; then
			echo "$name"; return 0
		fi
	done < <(lsblk -bdnp -o NAME,SIZE,TRAN,VENDOR,MODEL)
	return 1
}

wait_for_disk() {
	local want="$1" dev i
	for i in $(seq 1 60); do
		udevadm settle
		if dev=$(find_ums_disk "$want"); then
			echo "$dev"; return 0
		fi
		sleep 1
	done
	return 1
}

# Unmount anything the desktop may have mounted automatically.
unmount_disk() {
	local part
	for part in $(lsblk -lnp -o NAME "$1"); do
		umount "$part" 2>/dev/null || true
	done
}

# 1. Wait for the board in recovery mode.
if ! lsusb -d 0955:7140 > /dev/null; then
	echo "Waiting for a TK1 in recovery mode. To enter it, hold FORCE RECOVERY,"
	echo "press and release RESET, then release FORCE RECOVERY. On a board running"
	echo "this image, you can instead run:"
	echo "    sudo systemctl reboot --reboot-argument=forced-recovery"
	for i in $(seq 1 300); do
		lsusb -d 0955:7140 > /dev/null && break
		sleep 1
	done
	lsusb -d 0955:7140 > /dev/null || die "no TK1 in recovery mode found"
fi

# 2. Load the flashing U-Boot into the board's memory.
echo "Loading U-Boot into the board over USB..."
tegrarcm --bct="$fw/tk1.bct" --bootloader="$fw/u-boot-flash.bin" --loadaddr=0x80108000

# 3. Write the BCT and U-Boot to boot0, then eject it so U-Boot moves on.
dev=$(wait_for_disk boot0) || die "the board's boot0 area did not appear"
echo "Writing boot0 on $dev..."
unmount_disk "$dev"
dd if="$fw/boot0.img" of="$dev" bs=1M conv=fsync status=none
eject "$dev"

# 4. Partition the main storage, write the root filesystem, and eject it,
#    which makes U-Boot reset the board into the new install.
dev=$(wait_for_disk main) || die "the board's main storage did not appear"
echo "Partitioning $dev and writing the root filesystem..."
unmount_disk "$dev"
sgdisk --zap-all "$dev" > /dev/null
sgdisk -n 1:4MiB:0 -t 1:8300 -c 1:tk1root -A 1:set:2 "$dev" > /dev/null
partprobe "$dev"
udevadm settle
part="${dev}1"
[ -b "$part" ] || die "partition $part did not appear"
case "$img" in
	*.zst) zstd -dc "$img" ;;
	*) cat "$img" ;;
esac | dd of="$part" bs=4M conv=fsync status=progress
eject "$dev"

echo
echo "Done. The board is restarting into its new install. On its first boot it"
echo "names itself tk1-XXXX from its Ethernet MAC address and grows its"
echo "filesystem, which takes a minute or two."
