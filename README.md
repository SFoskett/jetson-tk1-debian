# Debian for the NVIDIA Jetson TK1

This project builds a Debian 13 (trixie) image for the NVIDIA Jetson TK1, using Debian's own mainline Linux kernel and the mainline U-Boot bootloader instead of NVIDIA's 2014-era Linux for Tegra. Boards running it get Debian security updates automatically, can run without a fan, and are set up to be secure and to spare their aging eMMC storage.

The image is meant for headless use, such as a UPS monitor with NUT or an SSH jump host, but it works with a monitor and keyboard too.

## What works

Gigabit Ethernet (with firmware), USB 3.0, the eMMC, HDMI video with a text console, HDMI audio, the SD card slot, SATA, the mini-PCIe slot, the serial console, the hardware watchdog, CPU frequency scaling, and thermal protection all work.

A few things are limited:

- **Fanless operation.** The image adds gradual CPU throttling that starts at 80°C, so a board with only its stock heat sink can run at full load indefinitely. Under sustained load on all four cores it holds about 84°C and keeps roughly 84% of its peak speed.
- **The GPU is powered off** by default, since headless boards don't use it. See "Using the GPU" below to turn it back on.
- **Analog audio does not work**, because Debian's kernel is built without the Tegra audio drivers it needs. It is disabled so it doesn't hold up booting.
- **The SD card slot runs in high-speed mode** (about 22 MB/s), since the Tegra124 driver does not offer the faster UHS modes.
- **Memory runs at a fixed 924 MHz.** Dynamic memory scaling was tested and found unstable on these boards, so it is not enabled.

## Security defaults

- SSH is the only service reachable from the network. A default-deny firewall drops all other incoming connections; see "Opening firewall ports" below.
- Root cannot log in, either at the console or over SSH. The default user has sudo access.
- SSH allows no root logins, limits login attempts, and disables agent, X11, and socket forwarding and tunneling. Local TCP forwarding stays on so the board can serve as an SSH jump host (`ssh -J`).
- Local-network name discovery (LLMNR and multicast DNS) is turned off.
- Debian security and stable updates install automatically every day. When an update requires it, such as a new kernel, the board reboots at 04:00 local time.
- If the system ever hangs, the hardware watchdog reboots the board after 30 seconds.

One risk comes with automatic updates: if a future kernel update failed to boot, an unattended board would reboot into it and stay down until someone reflashed it. Debian's kernels are well tested, so this is unlikely, but it is the price of automatic security patching.

## Sparing the eMMC

The eMMC in these boards is over a decade old, and if it wears out the board is unusable. The image reduces writes in several ways:

- **The system log is kept in RAM** (up to 32 MB) and is lost at every reboot. To keep logs on the eMMC instead, change `Storage=volatile` to `Storage=persistent` in `/etc/systemd/journald.conf.d/tk1.conf` and reboot.
- The filesystem flushes pending writes every 60 seconds instead of every 5, and does not record file access times. A sudden power loss can lose up to a minute of recent changes.
- `/tmp` is in RAM, and the eMMC is trimmed weekly to help its wear leveling.
- apt stores its package lists compressed and skips description translations, which greatly reduces the writes from its daily update check.

## Requirements

- An x86 Linux computer to build and flash with. These instructions were tested on Ubuntu.
- A micro-USB cable from that computer to the TK1's micro-USB port, which is used for flashing.
- Network access for the TK1 through its Ethernet port.
- Optionally, a serial console (the TK1's DB9 port, 115200 baud 8N1, through a null-modem adapter) or an HDMI monitor and USB keyboard. Neither is needed if you build the image with your own password or SSH key.

## Building the image

Install the build tools:

```
sudo apt install mmdebstrap qemu-user-binfmt debian-archive-keyring zstd git
```

On older releases, the emulator package may be called `qemu-user-static` instead.

Then personalize the build. Copy `local.conf.example` to `local.conf` and edit it to set your username, password, SSH public key, and time zone. Git ignores `local.conf`, so your settings stay on your computer. Create the password hash with `openssl passwd -6`, and give the full path to your SSH key file, since the build runs as root and `~` would mean root's home directory.

What you set decides how you log in the first time:

| Settings in local.conf | Password | SSH |
|---|---|---|
| SSH key and password | Yours | Keys only |
| SSH key only | `tk1`, must be changed at first login | Keys only |
| Password only | Yours | Passwords allowed |
| Neither, or no local.conf | `tk1`, must be changed at first login | Off until the password is changed at the console |

The last row keeps the publicly known default password off the network. SSH stays off until someone changes the password at the console, and then SSH starts and the lockout removes itself completely.

Build the image:

```
sudo ./build.sh 2>&1 | tee output/build.log
```

The build takes about 20 minutes on a fast computer, longer if the build directory is on slow storage such as an SD card. It produces `output/tk1-trixie-YYYYMMDD.img.zst` and a matching `.sha256` checksum file.

**Do not share an image built with a `local.conf`.** It contains your SSH public key and your password hash, and anyone with the image can attempt to crack the hash offline. To give someone an image, build one with settings meant for them, or build one with no `local.conf`, which uses the default password and the SSH lockout.

## Getting the flashing tools

Flashing uses two downloads:

1. **NVIDIA's L4T R19.3 driver package**, `Tegra124_Linux_R19.3.0_armhf.tbz2`, from NVIDIA's L4T archive at https://developer.nvidia.com/embedded/linux-tegra-archive (a free NVIDIA developer account may be required). It must be R19.3, since later versions flash a U-Boot that will not boot. Extract it with `sudo tar xpf Tegra124_Linux_R19.3.0_armhf.tbz2`, which creates `Linux_for_Tegra` (install `bzip2` first if needed).
2. **Debian's U-Boot for Tegra**, the armhf `u-boot-tegra` package for trixie from packages.debian.org. Unpack it without installing it: `dpkg -x u-boot-tegra_*_armhf.deb ~/uboot-tegra`.

## Flashing a board

Put the board in recovery mode: with it powered on, hold the FORCE RECOVERY button, press and release RESET, and release FORCE RECOVERY a second or two later. Check that the computer sees it:

```
lsusb | grep -i nvidia
```

It should show `0955:7140`. Then decompress the image into the L4T directory as `system.img` and flash:

```
zstd -dc output/tk1-trixie-YYYYMMDD.img.zst > ~/Linux_for_Tegra/bootloader/system.img
cd ~/Linux_for_Tegra
sudo ./flash.sh -r -L ~/uboot-tegra/usr/lib/u-boot/jetson-tk1/u-boot-tegra.bin -S 14580MiB jetson-tk1 mmcblk0p1
```

Flashing takes about two minutes and installs both U-Boot and Debian. Two details matter:

- `-r` tells flash.sh to use your image instead of building its own.
- The last argument must be `mmcblk0p1`. NVIDIA's tools treat `mmcblk1p1` as an SD card and silently skip writing the image, which leaves a board with U-Boot but nothing to boot.

The board restarts when flashing finishes. On its first boot, it names itself after the last two bytes of its Ethernet MAC address, such as `tk1-8e54`, grows its filesystem to fill the eMMC, and creates its own SSH host keys. Find its address in your router's DHCP client list, or try connecting by its hostname.

### Reflashing a running board remotely

A board running this image can be put into recovery mode without touching it:

```
sudo systemctl reboot --reboot-argument=forced-recovery
```

It restarts into recovery mode, ready to flash, and boots normally again afterward.

## Running the board

### Opening firewall ports

All incoming connections except SSH are dropped. To run a network service, you must open its port explicitly. Edit `/etc/nftables.conf`, add a rule in the marked section of the input chain, for example for a NUT server:

```
tcp dport 3493 accept
```

Then apply it with `sudo systemctl reload nftables`.

### Using the GPU

The GPU is powered off because its driver, nouveau, is blacklisted. To use it, delete `/etc/modprobe.d/blacklist-nouveau.conf` and `/etc/tk1/gpu-rail-off`, then rebuild the device tree and initramfs and reboot:

```
sudo /etc/kernel/postinst.d/50-tk1-dtb $(uname -r)
sudo update-initramfs -u
sudo reboot
```

### How the board-specific changes work

The TK1 needs some changes to Debian's device tree: disabling display hardware that blocks HDMI, disabling the unsupported analog audio, adding the gradual CPU throttling, and allowing the GPU's power rail to switch off. A kernel hook, `/etc/kernel/postinst.d/50-tk1-dtb`, applies these to each kernel Debian installs, so they carry through kernel updates automatically. The device tree changes are in `/etc/tk1/`.

## Troubleshooting

**The build stops with "filesystems are still mounted."** An earlier build was interrupted and left filesystems mounted inside its work directory. Make sure no `mmdebstrap` process is still running (`pgrep -a mmdebstrap`), then unmount them with the command the message shows. The build refuses to continue until they are gone, because deleting the work directory with them mounted would reach into the build computer's own system directories.

**The board does not appear in recovery mode.** Check that the cable is in the micro-USB port, try another cable (some are charge-only), and repeat the button sequence.

**The board has a new IP address after reflashing.** Images built before the DHCP change identified the board by a per-install ID instead of its MAC address. Current images keep the same address across reflashes and work with MAC-based DHCP reservations.
