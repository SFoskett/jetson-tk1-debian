#!/bin/bash
# mmdebstrap customize hook: configure the TK1 root filesystem.
# Called by build.sh with the root filesystem directory as $1.
set -euo pipefail
root="$1"
here="$(cd "$(dirname "$0")" && pwd)"
run() { chroot "$root" "$@"; }
export LC_ALL=C.UTF-8

# Copy the image's configuration files into place.
cp -r --preserve=mode "$here/files/." "$root/"

# systemd-networkd manages the network, so remove ifupdown.
run apt-get purge -y ifupdown
rm -f "$root/etc/network/interfaces"
run systemctl enable systemd-networkd tk1-firstboot.service

# Default login tk1/tk1, with the password expired so it must be changed
# at the first login. The root account stays locked.
run useradd -m -s /bin/bash -G sudo,adm tk1
echo tk1:tk1 | run chpasswd
run chage -d 0 tk1
run passwd -l root

# Build the device tree overlay, then regenerate everything that depends
# on the configuration files: the initramfs, the patched device tree for
# each kernel, and the U-Boot boot menu.
run dtc -I dts -O dtb -o /etc/tk1/tk1-display.dtbo /etc/tk1/tk1-display.dts
run update-initramfs -u -k all
for v in "$root"/lib/modules/*; do
	run /etc/kernel/postinst.d/50-tk1-dtb "$(basename "$v")"
done
run u-boot-update

run apt-get clean
