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
mkdir -p "$root/etc/tk1"
echo "$TK1_USER" > "$root/etc/tk1/default-user"

if [ -f "$keys" ]; then
	# With an SSH key, SSH accepts keys only.
	install -d -m 700 "$root/home/$TK1_USER/.ssh"
	install -m 600 "$keys" "$root/home/$TK1_USER/.ssh/authorized_keys"
	run chown -R "$TK1_USER:$TK1_USER" "/home/$TK1_USER/.ssh"
	printf 'PasswordAuthentication no\n' > "$root/etc/ssh/sshd_config.d/10-tk1-auth.conf"
elif [ -z "$TK1_PASSWORD_HASH" ]; then
	# No key and the publicly known default password: keep SSH off until
	# the password has been changed at the console.
	cp -r --preserve=mode "$here/optional/ssh-gate/." "$root/"
	run systemctl enable tk1-ssh-gate.path
	cat >> "$root/etc/issue" <<ISSUE
SSH is off until the default password is changed.
Log in here as $TK1_USER with password tk1 to set a new one.

ISSUE
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

run apt-get clean
