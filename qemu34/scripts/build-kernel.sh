#!/bin/bash
# runs INSIDE localhost/kbuild34:trusty, /w = ~/embedded34
set -euo pipefail
K=/w/src/linux-3.4.113
O=/w/build/kernel
mkdir -p $O
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
cd $K
make O=$O vexpress_defconfig
S="$K/scripts/config --file $O/.config"
$S -e ARCH_VEXPRESS_DT -e ARCH_VEXPRESS_CA9X4
$S -d ARM_LPAE -e AEABI -d OABI_COMPAT -e ARM_THUMB
$S -e VFP -e VFPv3 -e NEON
$S -e DEVTMPFS -e DEVTMPFS_MOUNT -e UNIX98_PTYS -e DEVPTS_MULTIPLE_INSTANCES
$S -e BLK_DEV_INITRD -e RD_GZIP -e TMPFS
$S -e SMSC911X -e SERIAL_AMBA_PL011 -e SERIAL_AMBA_PL011_CONSOLE
$S -e IPV6 -e PACKET -e UNIX -e INET
$S -e PROC_FS -e SYSFS -e PRINTK_TIME
$S -d DEBUG_INFO -d DEBUG_LL -d EARLY_PRINTK
$S --set-str CMDLINE "console=ttyAMA0"
$S -d SOUND -d LOGO
(set +o pipefail; yes "" | make O=$O oldconfig >/dev/null)
for c in ARCH_VEXPRESS_DT ARM_LPAE AEABI OABI_COMPAT ARM_THUMB VFP VFPv3 NEON DEVTMPFS DEVTMPFS_MOUNT UNIX98_PTYS BLK_DEV_INITRD SMSC911X SERIAL_AMBA_PL011_CONSOLE IPV6 SMP; do
  grep -E "^(# )?CONFIG_${c}[= ]" $O/.config || echo "MISSING $c"; done
make O=$O -j16 zImage
make O=$O vexpress-v2p-ca15-tc1.dtb vexpress-v2p-ca9.dtb
ls -la $O/arch/arm/boot/zImage $O/arch/arm/boot/*.dtb
