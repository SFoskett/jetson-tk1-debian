# Flashing with NVIDIA's L4T tools

Before this project had its own open-source flashing script, it used NVIDIA's flash.sh from the Linux for Tegra (L4T) R19.3 package. That method still works, and this guide documents it for anyone who already has L4T set up. For everyone else, the [main README](../README.md) describes the recommended open-source process, which needs no proprietary downloads.

Build the image first, as described in the main README.

## Getting the tools

1. **NVIDIA's L4T R19.3 driver package**, `Tegra124_Linux_R19.3.0_armhf.tbz2`, from NVIDIA's L4T archive at https://developer.nvidia.com/embedded/linux-tegra-archive (a free NVIDIA developer account may be required). It must be R19.3, since later versions flash a U-Boot that will not boot. Extract it with `sudo tar xpf Tegra124_Linux_R19.3.0_armhf.tbz2`, which creates `Linux_for_Tegra` (install `bzip2` first if needed). Its flashing tool, nvflash, is a 32-bit program, but it is statically linked, so it runs on a 64-bit system without extra libraries.
2. **Debian's U-Boot.** The build saves it as `output/flash/u-boot.bin`.

## Flashing

Put the board in recovery mode: with it powered on, hold FORCE RECOVERY, press and release RESET, and release FORCE RECOVERY a second or two later. A board running this image can instead be sent there with `sudo systemctl reboot --reboot-argument=forced-recovery`. Check that your computer sees it with `lsusb | grep -i nvidia`, which should show `0955:7140`.

Decompress the image into the L4T directory as `system.img`, then flash:

```
zstd -dc output/tk1-trixie-YYYYMMDD.img.zst > ~/Linux_for_Tegra/bootloader/system.img
cd ~/Linux_for_Tegra
sudo ./flash.sh -r -L /path/to/output/flash/u-boot.bin -S 14580MiB jetson-tk1 mmcblk0p1
```

Flashing takes about two minutes and installs both U-Boot and Debian. Two details matter:

- `-r` tells flash.sh to use your image instead of building its own.
- The last argument must be `mmcblk0p1`. NVIDIA's tools treat `mmcblk1p1` as an SD card and silently skip writing the image, which leaves a board with U-Boot but nothing to boot.

## How the result differs

This method keeps NVIDIA's partition layout. The eMMC's main storage has NVIDIA's hidden partitions, the root filesystem in a 14.2 GB partition called APP, and several small partitions that go unused. NVIDIA's boot configuration also loads U-Boot from one of the hidden partitions instead of from the boot0 area.

The installed Debian system is the same either way. A board flashed with this method can later be reflashed with `flash-tk1.sh`, which converts it to the simpler layout.
