# Debian for the NVIDIA Jetson TK1

This project builds a Debian 13 (trixie) image for the NVIDIA Jetson TK1 and flashes it using only open-source tools. Boards run Debian's own mainline Linux kernel and the mainline U-Boot bootloader instead of NVIDIA's 2014-era Linux for Tegra, get Debian security updates automatically, can run without a fan, and are set up to be secure and to spare their aging eMMC storage.

The image is meant for headless use, such as a UPS monitor with NUT or an SSH jump host, but it works with a monitor and keyboard too.

This README covers the recommended, fully open-source process. Two other installation methods are documented separately:

- [Manual installation with the serial console](docs/manual-install.md) does the same steps by hand at U-Boot's prompt. It is useful for understanding the process and for recovering a board when something goes wrong.
- [Flashing with NVIDIA's L4T tools](docs/l4t-flash.md) uses NVIDIA's proprietary flash.sh, for anyone who already has it set up.

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
- A micro-USB cable from that computer to the TK1's micro-USB port.
- Network access for the TK1 through its Ethernet port.

No serial console, monitor, or keyboard is needed if you build the image with your own password or SSH key.

Install the tools for building and flashing:

```
sudo apt install mmdebstrap qemu-user-binfmt debian-archive-keyring zstd git \
	cbootimage device-tree-compiler python3 tegrarcm gdisk
```

On older releases, the emulator package may be called `qemu-user-static` instead.

## Building the image

Personalize the build first. Copy `local.conf.example` to `local.conf` and edit it to set your username, password, SSH public key, and time zone. Git ignores `local.conf`, so your settings stay on your computer. Create the password hash with `openssl passwd -6`, and give the full path to your SSH key file, since the build runs as root and `~` would mean root's home directory.

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
sudo ./build.sh
```

The build takes about 25 minutes on a fast computer, longer if the build directory is on slow storage such as an SD card. Run it directly in a terminal, since its progress bars only appear there. To also keep a log, run it with `script`, which records the output while keeping the progress bars:

```
sudo script -q -c ./build.sh /tmp/tk1-build.log
```

Avoid piping the build through `tee` or similar, which hides the progress bars and has been seen to leave the build stopped partway through.

When the build finishes, it gives `output/` and everything in it back to your account. It produces:

- `output/tk1-trixie-YYYYMMDD.img.zst`, the root filesystem image, and a matching `.sha256` checksum file.
- `output/flash/`, the files for flashing: the boot configuration table (`tk1.bct`), the boot image for the eMMC (`boot0.img`), Debian's U-Boot (`u-boot.bin`), and a copy of it that runs the flashing steps on its own (`u-boot-flash.bin`).

**Do not share an image built with a `local.conf`.** It contains your SSH public key and your password hash, and anyone with the image can attempt to crack the hash offline. To give someone an image, build one with settings meant for them, or build one with no `local.conf`, which uses the default password and the SSH lockout.

## Flashing a board

Put the board in recovery mode: with it powered on, hold the FORCE RECOVERY button, press and release RESET, and release FORCE RECOVERY a second or two later. Then run:

```
sudo ./flash-tk1.sh
```

The script uses the newest image in `output/`, or you can give it the path of a specific image. It takes about two minutes:

1. It sends the boot configuration and the flashing copy of U-Boot to the board's memory over USB with tegrarcm. U-Boot resets any settings saved on the board, then makes the eMMC appear on your computer as a USB disk.
2. It writes the boot configuration and U-Boot to the eMMC's boot0 area.
3. It replaces the eMMC's main storage with a single partition labeled `tk1root` and writes the root filesystem into it.
4. The board resets and boots its new install.

The script only writes to disks that identify themselves as U-Boot's USB storage device and have the expected size, so it will not touch your computer's own drives or other USB disks. It works on any TK1, whatever was installed before, including NVIDIA's original software and images flashed with the other methods.

On its first boot, the board names itself after the last two bytes of its Ethernet MAC address, such as `tk1-8e54`, grows its filesystem to fill the eMMC, and creates its own SSH host keys. It identifies itself to your DHCP server by its MAC address, so it keeps the same IP address when reflashed, and DHCP reservations by MAC address work. Find its address in your router's DHCP client list, or try connecting by its hostname.

### Reflashing a running board remotely

A board running this image can be put into recovery mode without touching it:

```
sudo systemctl reboot --reboot-argument=forced-recovery
```

It restarts into recovery mode, ready for `flash-tk1.sh`.

### Checking a board's memory

The boot configuration sets up the board's memory once at power-on, and nothing changes those settings afterward. They were tested for 30 minutes of full memory load without errors, but these boards are old, so it is worth testing each one once. On the board:

```
sudo apt update && sudo apt install stressapptest
stressapptest -s 1800 -M 1200 -W
```

It should end with `Status: PASS`. Any errors suggest a failing board.

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

**The board does not appear in recovery mode.** Check that the cable is in the micro-USB port, try another cable (some are charge-only), and repeat the button sequence. `lsusb | grep -i nvidia` should show `0955:7140`.

**Flashing stops partway.** Put the board back in recovery mode and run `flash-tk1.sh` again. Recovery mode is built into the Tegra chip and always works, so an interrupted flash cannot leave a board unrecoverable. To see what the board is doing during a flash, connect a serial console as described in the [manual installation guide](docs/manual-install.md).

## License

The scripts and configuration files in this repository are released under the MIT License; see `LICENSE`. The files in `flash/` come from NVIDIA's cbootimage-configs project under their own permissive license; see `flash/README.md`. The images this project builds contain Debian, the Linux kernel, U-Boot, and firmware, each under its own license.
