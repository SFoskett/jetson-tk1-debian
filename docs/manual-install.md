# Manual installation with the serial console

This guide installs the image by hand from U-Boot's command prompt, using a serial console and U-Boot's USB mass storage mode. It is how this project was first developed. `flash-tk1.sh` automates exactly these steps, so this guide is mainly for understanding the process, debugging, and recovering a board when something goes wrong.

Build the image first, as described in the [main README](../README.md). The build's `output/flash/` directory has everything used here.

## Connecting a serial console

The TK1's DB9 port is a real RS-232 serial port, running at 115200 baud, 8 data bits, no parity, 1 stop bit. You need a USB-to-serial adapter and a null-modem adapter or cable between it and the TK1.

On Linux, the adapter usually appears as `/dev/ttyUSB0`. Your account needs to be in the `dialout` group to open it (`sudo usermod -aG dialout $USER`, then log out and back in), or use sudo. Then connect with any terminal program, for example:

```
screen /dev/ttyUSB0 115200
```

U-Boot gives you very little time to interrupt its countdown. Holding a key down, such as the space bar, while the board starts lets your keyboard's auto-repeat catch the window.

## Starting U-Boot from recovery mode

Put the board in recovery mode: hold FORCE RECOVERY, press and release RESET, and release FORCE RECOVERY a second or two later. A board running this image can instead be sent there with `sudo systemctl reboot --reboot-argument=forced-recovery`. From U-Boot's prompt, `mw.l 0x7000e450 0x2` followed by `reset` does the same, since it sets the chip's recovery flag before restarting.

Check that your computer sees the board:

```
lsusb | grep -i nvidia
```

It should show `0955:7140`. Then send the boot configuration and Debian's unmodified U-Boot to the board's memory:

```
sudo tegrarcm --bct=output/flash/tk1.bct --bootloader=output/flash/u-boot.bin --loadaddr=0x80108000
```

U-Boot starts from memory. Interrupt its countdown on the serial console to reach the `Tegra124 (Jetson TK1) #` prompt. If you miss it, U-Boot boots whatever is already on the eMMC; return to recovery mode and try again.

## Writing boot0

The eMMC's boot0 area holds the boot configuration and U-Boot, which the Tegra chip reads at power-on. At the U-Boot prompt, expose boot0 to your computer as a USB disk:

```
ums 0 mmc 0.1
```

On your computer, find the new 4 MB disk with `lsblk`, then write the boot image to it and eject it. In these commands, replace `sdX` with that disk's name, and check it carefully, since writing to the wrong disk destroys its contents:

```
sudo dd if=output/flash/boot0.img of=/dev/sdX bs=1M conv=fsync
sudo eject /dev/sdX
```

Ejecting ends `ums` and returns U-Boot to its prompt. U-Boot then prints "CTRL+C - Operation aborted", which is normal, since both kinds of exit share that message.

U-Boot keeps its saved settings in the eMMC's boot1 area. Settings saved by an older U-Boot can interfere with booting, so reset them to the defaults:

```
env default -a
env save
```

## Writing the main storage

Expose the main storage:

```
ums 0 mmc 0
```

U-Boot can expose only one area of the eMMC at a time. Asking for both at once, as in `ums 0 mmc 0,0.1`, makes the main storage fail with errors, because U-Boot does not switch back to it after setting up boot0.

On your computer, find the new disk of about 14.7 GB. Replace its partitions with a single partition labeled `tk1root`, starting at 4 MiB so it lines up with the eMMC's 2 MB erase blocks, write the root filesystem into it, and eject:

```
sudo sgdisk --zap-all /dev/sdX
sudo sgdisk -n 1:4MiB:0 -t 1:8300 -c 1:tk1root -A 1:set:2 /dev/sdX
sudo partprobe /dev/sdX
zstd -dc output/tk1-trixie-YYYYMMDD.img.zst | sudo dd of=/dev/sdX1 bs=4M conv=fsync status=progress
sudo eject /dev/sdX
```

Back at the U-Boot prompt, type `reset`. The board boots from the eMMC into its new install.

## Useful U-Boot commands

- `version` shows the U-Boot version.
- `mmc part` lists the partitions on the eMMC.
- `ext4ls mmc 0:1 /` lists the root directory of the first partition, which is a quick way to check that U-Boot can read the filesystem.
- `boot` runs the normal boot process.
