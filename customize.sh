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
run systemctl enable systemd-networkd nftables tk1-firstboot.service

# Create the default user from the settings build.sh passed along.
# A default password of tk1 is always expired, so it must be changed at
# the first login. The root account stays locked.
. "$here/output/work/user.conf"
keys="$here/output/work/authorized_keys"
run useradd -m -s /bin/bash -G sudo,adm "$TK1_USER"
if [ -n "$TK1_PASSWORD_HASH" ]; then
	run usermod -p "$TK1_PASSWORD_HASH" "$TK1_USER"
else
	echo "$TK1_USER:tk1" | run chpasswd
	run chage -d 0 "$TK1_USER"
fi
run passwd -l root

# Time zone, which also sets when automatic reboots happen.
if [ ! -f "$root/usr/share/zoneinfo/$TK1_TIMEZONE" ]; then
	echo "customize.sh: unknown time zone $TK1_TIMEZONE" >&2
	exit 1
fi
ln -sf "/usr/share/zoneinfo/$TK1_TIMEZONE" "$root/etc/localtime"
echo "$TK1_TIMEZONE" > "$root/etc/timezone"

# Locale. SSH passes the connecting computer's locale to the board, so the
# image generates one locale, by default the build machine's. C.UTF-8 is
# built in and needs nothing generated.
case "$TK1_LOCALE" in
	C | POSIX | C.UTF-8 | C.utf8)
		echo "LANG=C.UTF-8" > "$root/etc/default/locale"
		;;
	*)
		locale=$(echo "$TK1_LOCALE" | sed 's/\.utf-\{0,1\}8$/.UTF-8/I')
		entry=$(awk -v l="$locale" '$1 == l { print; exit }' "$root/usr/share/i18n/SUPPORTED")
		if [ -z "$entry" ]; then
			echo "customize.sh: locale $locale is not in Debian's list of supported locales" >&2
			exit 1
		fi
		echo "$entry" > "$root/etc/locale.gen"
		run locale-gen
		echo "LANG=$locale" > "$root/etc/default/locale"
		;;
esac

# Multicast DNS, which lets other computers reach the board by its .local
# name, such as tk1-8e54.local. resolved answers mDNS only on interfaces
# where networkd also enables it, and the firewall must accept UDP 5353.
mkdir -p "$root/etc/systemd/network/20-wired.network.d"
if [ "$TK1_MDNS" = yes ]; then
	printf '[Resolve]\nMulticastDNS=yes\n' > "$root/etc/systemd/resolved.conf.d/tk1-mdns.conf"
	printf '[Network]\nMulticastDNS=yes\n' > "$root/etc/systemd/network/20-wired.network.d/mdns.conf"
	sed -i 's|^\t\ttcp dport 22 accept$|\t\ttcp dport 22 accept\n\n\t\t# Multicast DNS, so the board answers to its .local name.\n\t\tudp dport 5353 accept|' "$root/etc/nftables.conf"
	grep -q 'udp dport 5353 accept' "$root/etc/nftables.conf" || { echo "customize.sh: could not add the mDNS firewall rule" >&2; exit 1; }
else
	printf '[Resolve]\nMulticastDNS=no\n' > "$root/etc/systemd/resolved.conf.d/tk1-mdns.conf"
	printf '[Network]\nMulticastDNS=no\n' > "$root/etc/systemd/network/20-wired.network.d/mdns.conf"
fi

if [ -f "$keys" ]; then
	# With an SSH key, SSH accepts keys only.
	install -d -m 700 "$root/home/$TK1_USER/.ssh"
	install -m 600 "$keys" "$root/home/$TK1_USER/.ssh/authorized_keys"
	run chown -R "$TK1_USER:$TK1_USER" "/home/$TK1_USER/.ssh"
	printf 'PasswordAuthentication no\n' > "$root/etc/ssh/sshd_config.d/10-tk1-auth.conf"
elif [ -z "$TK1_PASSWORD_HASH" ]; then
	# No key and the publicly known default password: keep SSH off until
	# the password has been changed at the console. The lockout removes
	# itself completely once that happens.
	cp -r --preserve=mode "$here/optional/ssh-gate/." "$root/"
	echo "$TK1_USER" > "$root/etc/tk1/default-user"
	mkdir -p "$root/etc/issue.d"
	cat > "$root/etc/issue.d/tk1-ssh-gate.issue" <<ISSUE
SSH is off until the default password is changed.
Log in here as $TK1_USER with password tk1 to set a new one.

ISSUE
	run systemctl enable tk1-ssh-gate.path
fi

# Build the device tree overlay, then regenerate everything that depends
# on the configuration files: the initramfs, the patched device tree for
# each kernel, and the U-Boot boot menu.
run dtc -I dts -O dtb -o /etc/tk1/tk1-display.dtbo /etc/tk1/tk1-display.dts
run update-initramfs -u -k all
for v in "$root"/lib/modules/*; do
	run /etc/kernel/postinst.d/50-tk1-dtb "$(basename "$v")"
done
run u-boot-update

# Save the build time where systemd looks for the last known time, so a
# first boot without network starts with the clock at the build date.
run mkdir -p /var/lib/systemd/timesync
run touch /var/lib/systemd/timesync/clock
if run getent passwd systemd-timesync > /dev/null; then
	run chown -R systemd-timesync:systemd-timesync /var/lib/systemd/timesync
fi

# Save the TK1's U-Boot for the flashing files, then remove the package,
# which holds U-Boot builds for many boards and is not needed on the TK1.
cp "$root/usr/lib/u-boot/jetson-tk1/u-boot-tegra.bin" "$here/output/work/u-boot-tegra.bin"
run apt-get purge -y u-boot-tegra

run apt-get clean
