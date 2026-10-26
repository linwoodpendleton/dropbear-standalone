#!/bin/bash
# runs INSIDE localhost/kbuild34:trusty
set -euo pipefail
mkdir -p /w/build && cd /w/build
rm -rf busybox-1.36.1 && tar xjf /w/dl/busybox/busybox-1.36.1.tar.bz2
cd busybox-1.36.1
make defconfig >/dev/null
set_y(){ sed -i "s/^# CONFIG_$1 is not set/CONFIG_$1=y/; s/^CONFIG_$1=.*/CONFIG_$1=y/" .config; }
set_n(){ sed -i "s/^CONFIG_$1=.*/# CONFIG_$1 is not set/" .config; }
set_y STATIC
set_y USE_BB_PWD_GRP
set_y USE_BB_SHADOW
sed -i "s|^CONFIG_CROSS_COMPILER_PREFIX=.*|CONFIG_CROSS_COMPILER_PREFIX=\"arm-linux-gnueabihf-\"|" .config
sed -i "s|^CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS=\"-march=armv7-a -mfloat-abi=hard -mfpu=vfpv3-d16\"|" .config
set_n TC   # 3.x-era headers vs new tc code
set_n SEEDRNG   # needs sys/random.h (glibc>=2.25)
(set +o pipefail; yes "" | make oldconfig >/dev/null)
make -j16 busybox
arm-linux-gnueabihf-strip -o /w/build/busybox busybox
file /w/build/busybox
