# Linux 3.4.113 ARMv7 测试环境(qemu-system-arm / vexpress-a15)

用途:在**真实的 3.4 内核**上验证静态 ARMv7 Cortex-A7 硬浮点(`-mfpu=neon-vfpv4`)二进制,
即打过补丁的 dropbear(`../out/dropbearmulti`)。

> 本仓库**不包含**内核、DTB、initramfs 和 busybox 二进制,只包含构建它们的脚本和配置;用 `scripts/` 按下文“构建 + 冒烟”自己生成。
> QEMU 10.2 在 `-M vexpress-a15` 上需要 `-cpu cortex-a15`(`CPU=cortex-a15 ./run-qemu.sh`)。

## 目录内容(构建后)

| 文件 | 说明 |
|---|---|
| `zImage` | Linux **3.4.113**(kernel.org 原版 tarball,GPG + sha256 已校验),vexpress_defconfig + DT,SMP |
| `vexpress-v2p-ca15-tc1.dtb` | 主用 DTB(qemu `-M vexpress-a15`) |
| `vexpress-v2p-ca9.dtb` | 仅作对照(`-M vexpress-a9`),**A9 没有 VFPv4,neon-vfpv4 二进制会 SIGILL**(已实测) |
| `initramfs-nopasswd.cpio.gz` | 基础根文件系统,**故意不含 /etc/passwd**(默认用这个) |
| `initramfs-passwd.cpio.gz` | 同上,多一个 `/etc/passwd`(`root:x:0:0:root:/root:/bin/sh`)+ `/etc/group` |
| `busybox-1.36.1-armhf-static` | rootfs 里的 busybox(armv7-a 硬浮点,静态 glibc 2.19,`USE_BB_PWD_GRP=y`) |
| `kernel-3.4.113-vexpress.config` / `busybox-1.36.1.config` | 构建用的完整配置 |
| `run-qemu.sh` | 一键启动(交互式串口) |
| `examples/vfpv4-fma/` | 一个用 `vfma.f64` 的静态小程序 + test.sh,用来证明 CPU/内核能跑 VFPv4 |
| `examples/test.sh.dropbear-example` | dropbear 测试脚本样例 |
| `scripts/` | 全部构建脚本(容器文件、内核/busybox 构建、mkrootfs、smoke test、/init 源码) |

内核关键配置:`ARCH_VEXPRESS_DT=y`、`ARM_LPAE` 关、`AEABI=y`、`OABI_COMPAT` 关、`ARM_THUMB=y`、
`VFP/VFPv3/NEON=y`、`DEVTMPFS(+_MOUNT)`、`UNIX98_PTYS`、`BLK_DEV_INITRD`+gzip、`SMSC911X`(板载 LAN9118 网卡)、
PL011 串口控制台 `ttyAMA0`、`IPV6=y`。时钟源用板载 SP804(3.4 的 vexpress DT 不用 arch timer)。

客户机里 `/proc/cpuinfo` 实测:
`Features: swp half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt`(`-cpu cortex-a7`,CPU part 0xc07)。

## /init 行为

1. 挂 `proc / sys / devtmpfs / devpts(ptmxmode=666) / tmpfs(/tmp, /dev/shm)`,`busybox --install -s`;
2. `lo` 起来;`eth0` 默认静态 `10.0.2.15/24 gw 10.0.2.2`(qemu user 网络);内核命令行带 `net=dhcp` 则用 udhcpc;
3. **钩子:若存在 `/data/test.sh`,执行一次**(输出到串口);
4. 内核命令行带 `testexit=poweroff` 则跑完关机(适合脚本化),否则串口上给一个 busybox shell(循环重生)。

串口上的标记行都以 `NK34-INIT:` 开头,方便 grep。

## 在 RK3588 板子(Ubuntu arm64)上运行

RK3588 上 **KVM 不能跑 32 位 EL1 的客户机**(A76 核不支持 AArch32 EL1,KVM 要求所有核都支持,
所以 `-enable-kvm -cpu host,aarch64=off` 不可用),只能 **TCG 纯模拟**,这对功能验证足够。

```sh
sudo apt install qemu-system-arm      # Ubuntu 22.04 带 qemu 6.2,24.04 带 8.2,都可以
# 把整个 qemu34 目录拷到板子上,例如 ~/qemu34
cd ~/qemu34
./run-qemu.sh                          # 交互式;退出:Ctrl-A x
```

`run-qemu.sh` 实际执行的命令(等价):

```sh
qemu-system-arm -M vexpress-a15 -cpu cortex-a7 -smp 2 -m 256 \
  -kernel zImage -dtb vexpress-v2p-ca15-tc1.dtb -initrd <base+追加cpio> \
  -append "console=ttyAMA0 rdinit=/init" \
  -nic user,hostfwd=tcp:127.0.0.1:2222-:22 -audio none -nographic
```

可调环境变量:`VARIANT=nopasswd|passwd`、`CPU=cortex-a7|cortex-a15`、`PORT=2222`、`SMP`、`MEM`、
`APPEND="net=dhcp testexit=poweroff"`。qemu < 7.1 没有 `-audio`,脚本会自动改用 `QEMU_AUDIO_DRV=none`
(否则只是一堆无害的 ALSA 报错)。

**不要用 `-cpu cortex-a9` / `-M vexpress-a9`**:A9 只有 VFPv3,用 `-mfpu=neon-vfpv4` 编的 dropbear 会
`Illegal instruction`(已用 `examples/vfpv4-fma` 实测确认)。

## 追加 dropbear + 测试脚本(第二个 cpio)

Linux 支持把多个 gzip 的 newc cpio **直接首尾拼接**当一个 initramfs;后面的会覆盖/补充前面的。
`/init` 只关心 `/data/test.sh`。打包(主机上只需 cpio + gzip,不需要 root):

```sh
cp examples/test.sh.dropbear-example test.sh      # 按需修改
# 可选:放一个公钥,样例脚本会用 -k 传给 dropbear
cp ~/.ssh/id_ed25519.pub id.pub
bash scripts/mkdata-cpio.sh dropbear-data.cpio.gz ../out/dropbearmulti test.sh id.pub
# 等价的手工写法:
#   mkdir -p x/data && cp ../out/dropbearmulti test.sh x/data/ && chmod 755 x/data/*
#   (cd x && find data | cpio -o -H newc -R 0:0) | gzip -9n > dropbear-data.cpio.gz

./run-qemu.sh dropbear-data.cpio.gz               # run-qemu.sh 会把 base + 追加的 cpio 拼起来
# 等价:cat initramfs-nopasswd.cpio.gz dropbear-data.cpio.gz > initrd.gz ,再 -initrd initrd.gz
```

另开一个终端连进去(主机 127.0.0.1:2222 → 客户机 22):

```sh
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1
```

测 "有 /etc/passwd" 的情况:`VARIANT=passwd ./run-qemu.sh dropbear-data.cpio.gz`。
脚本化回归:`APPEND=testexit=poweroff ./run-qemu.sh x.cpio.gz < /dev/null > serial.log`,test.sh 结束就关机。
注意 test.sh 里后台起的服务在 `testexit=poweroff` 下会随关机消失,自动化时应在 test.sh 里自己等待/自测完再返回。

## 构建 + 冒烟(x86_64 Linux 主机)

工作目录 `~/embedded34/`(`dl/` 下载、`src/` 内核源码、`build/` 构建树、`qemu34/` 产物)。全部在 rootless podman 里:

- `localhost/kbuild34:trusty`(Ubuntu 14.04:gcc-arm-linux-gnueabihf **4.8.4**、make 3.81、perl 5.18 —— 老 perl 不会触发
  `timeconst.pl` 的 `defined(@array)` 致命错误,所以不用打补丁);
- `localhost/qemu-arm:24.04`(qemu-system-arm 8.2.2)。

```sh
podman run --rm --userns=keep-id -v ~/embedded34:/w:Z localhost/kbuild34:trusty /w/scripts/build-kernel.sh
podman run --rm --userns=keep-id -v ~/embedded34:/w:Z localhost/kbuild34:trusty /w/scripts/build-busybox.sh
bash qemu34/scripts/mkrootfs.sh build/busybox build/kernel/usr/gen_init_cpio qemu34/scripts qemu34
podman run --rm -v ~/embedded34/qemu34:/w:Z localhost/qemu-arm:24.04 bash /w/scripts/smoke-test.sh nopasswd cortex-a7
```

(3.4 没有 `olddefconfig`,脚本用 `yes "" | make oldconfig`;busybox 关掉 `SEEDRNG`(要 glibc ≥ 2.25 的 sys/random.h)和 `TC`。)

冒烟结果(x86_64 主机,TCG):`uname -r` = `3.4.113`;qemu 启动到 test.sh 就绪 **约 2.8 s**(cortex-a7)/ 3.0 s(cortex-a15),
内核约 1.4 s 进 /init;hostfwd 2222→22 上的 busybox nc 应答 `NK34-NC-OK 3.4.113`;`net=dhcp` 拿到 10.0.2.15、DNS 10.0.2.3;
`vfma.f64` 程序在 a7 上 OK、在 a9 上 SIGILL。

**容器注意**:rootless podman 用 `-p 127.0.0.1:X:2222` 转发时 TCP 能连上但收不到数据;
要从宿主机访问 hostfwd 端口,qemu 容器用 `--network=host`(并让 hostfwd 绑 `127.0.0.1:<空闲端口>`)。直接在主机上原生跑 qemu 无此问题。

## 已知无害的启动信息

- `CPU1: Unknown IPI message 0x1`(3.4 + 新版 qemu 的 SMP 启动,无影响);
- `clcd-pl11x: probe ... failed`、`nxp-isp1760 ... Scratch test failed`(显示/USB 控制器,用不到);
- DTB 里写的是 cortex-a15,用 `-cpu cortex-a7` 时内核按 MIDR 识别为 A7,正常。

## 其它注意

- busybox 是静态 **glibc**(不是 musl):`USE_BB_PWD_GRP=y` 所以 busybox 自身不依赖 NSS;但 busybox 里按**主机名**
  解析(wget/nslookup 等)在静态 glibc 下可能不可用 —— 测试一律用 IP。被测的 dropbear 是 musl 静态,与此无关。
- 根文件系统全在内存(initramfs),每次启动都是干净状态;`/tmp`、`/dev/shm` 是 tmpfs。
