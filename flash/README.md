# Boot configuration files

These two files come unmodified from NVIDIA's cbootimage-configs project
(https://github.com/NVIDIA/cbootimage-configs, `tegra124/nvidia/jetson-tk1/`),
which distributes them under the zlib-style license in each file's header.

- `PM375_Hynix_2GB_H5TC4G63AFR_RDA_924MHz.bct.cfg` describes the Jetson TK1's
  memory and boot settings. `build.sh` compiles it into the BCT (boot
  configuration table) with cbootimage. It holds one identical parameter set
  for each of the four RAM codes, so it suits every TK1 board revision.
- `jetson-tk1-emmc.img.cfg` tells cbootimage how to combine the BCT and U-Boot
  into the image written to the eMMC's boot0 area.
