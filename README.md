# dropbear-armv7：单文件、零依赖的 SSH 服务端（ARMv7 Cortex-A7）

> **English: see [the English section](#english) at the end.**
>
> 这是一个开发/测试用工具，只在 QEMU 和 RK3588 的 AArch32 兼容模式下验证过，见“[已知限制](#已知限制)”。

两个发布文件（在 GitHub Releases 下载，`build.sh` 构建时输出到 `out/` 和 `out/variants/`），任选其一，都是单个静态可执行文件：

| 文件 | 大小（字节） | 内容 | sha256 |
|---|---:|---|---|
| `dropbearmulti`（主发布件） | 110,232 | `dropbear` 服务端 + `dropbearkey` + `scp`（只做被调用端） | `0322fc4a…1cddc5b2` |
| `dropbearmulti-client`（第二个发布件） | 157,360 | 以上全部 + `dbclient`（ssh 客户端），`scp` 可以在板子上主动发起 | `8ee4a0fc…bf8ae212` |

完整校验值见 `SHA256SUMS`。

只需要让别人登录板子，用第一个；板子自己还要去连别的机器（执行命令、端口转发、拷文件），用第二个。
第二个的说明见下文“[第二个发布件：dropbearmulti-client](#第二个发布件dropbearmulti-client带-ssh-客户端)”。

`out/dropbearmulti` 是**一个文件**：110,232 字节，静态链接（musl），里面包含
`dropbear`（服务端）、`dropbearkey`（生成密钥）和 `scp`（旧 scp 协议）。

- 目标平台：ARMv7 Cortex-A7，32 位小端，硬浮点（`-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -mthumb`，
  也就是 OpenWrt 的 `arm_cortex-a7_neon-vfpv4`），Linux **3.4 及以上**内核。
- 运行时**不需要**：共享库、动态加载器、libcrypt/zlib/libutil、`/etc/passwd`、`/etc/shadow`、`/etc/group`、
  `/etc/shells`、`/etc/hosts`、`/etc/resolv.conf`、PAM、syslogd、配置文件或 `scp` 程序。
- 以**当前用户**身份运行（root 和非 root 都可以）。它不做 setuid，不做 chroot；被装成 setuid/setgid 时拒绝运行（见“安全说明”）。
- 来源：Dropbear 2026.94（已校验 GPG 签名）、musl 1.2.6，以及 musl.libc.org 截至 2026-10 公布的三个 CVE 补丁。

```
$ file dropbearmulti
dropbearmulti: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), statically linked, stripped
$ readelf -d dropbearmulti
There is no dynamic section in this file.          # 没有 NEEDED，也没有 INTERP 段
sha256  0322fc4aad0a8d88c243c0f0f16fccb400e171256eca458a1227a3301cddc5b2
```

## 快速上手

```sh
chmod +x dropbearmulti
./dropbearmulti dropbear -h          # 查看全部选项
```

**1. 先在电脑上生成密码哈希**（推荐用 `-H`，不要把明文密码写在命令行上）：

```sh
openssl passwd -6                       # SHA-512 crypt，推荐；输出形如 $6$盐$哈希
mkpasswd -m sha-512                     # Debian 的 whois 包里有这个命令
python3 -c 'import crypt,getpass; print(crypt.crypt(getpass.getpass(), crypt.mksalt(crypt.METHOD_SHA512)))'
```

哈希里有 `$`，在 shell 里一定要用**单引号**括起来；或者写进文件用 `-H @文件`。

**2. 在板子上启动**（下面的例子都以普通用户身份运行，端口 ≥1024；root 启动见“安全说明”）：

```sh
# 前台运行，日志写 stderr。第一次有客户端连接时，-R 在 -r 指定的文件里生成主机密钥（0600）
./dropbearmulti dropbear -F -E -R -r /data/ssh_host_ed25519 -p 2222 \
    -U admin -H '$6$Qx1...$...'

# 哈希和公钥都放文件里（推荐给 init 脚本用）
printf '%s\n' '$6$Qx1...$...' > /data/admin.hash && chmod 600 /data/admin.hash
cat id_ed25519.pub >> /data/authorized_keys && chmod 600 /data/authorized_keys
./dropbearmulti dropbear -F -E -R -r /data/ssh_host_ed25519 -p 2222 \
    -U admin -H @/data/admin.hash -K /data/authorized_keys

# 只允许公钥登录（不给 -P/-H 就没有密码登录）；-k 可以写多次
./dropbearmulti dropbear -F -E -R -r /data/ssh_host_ed25519 -p 2222 \
    -U admin -k 'ssh-ed25519 AAAAC3Nza... me@pc' -k 'ssh-ed25519 AAAAC3Nza... ci@build'

# 临时调试用明文密码（会在 ps 里短暂可见；也可以用 -P @文件 或环境变量 DROPBEAR_PASSWORD）
DROPBEAR_PASSWORD='test123' ./dropbearmulti dropbear -F -E -R -r /tmp/hk -p 2222 -U dev

# 后台运行（不加 -F），写 pid 文件。注意：这个版本没有 syslog，后台运行时日志会丢掉
./dropbearmulti dropbear -R -r /data/ssh_host_ed25519 -p 2222 -x /tmp/dropbear.pid \
    -U admin -H @/data/admin.hash
kill "$(cat /tmp/dropbear.pid)"         # 停止
```

`-r`、`-K`、`-x` 写相对路径也可以：启动时会按当前目录换算成绝对路径（后台模式会 `chdir /`，以前相对路径会落到 `/` 下）。

交给 init 托管（前台 + 日志重定向），例如 busybox `/etc/inittab`：

```
::respawn:/data/dropbearmulti dropbear -F -E -R -r /data/ssh_host_ed25519 -p 2222 -U admin -H @/data/admin.hash -K /data/authorized_keys
```

或者 OpenWrt procd：`procd_set_param command /data/dropbearmulti dropbear -F -E ...`，再加 `procd_set_param stderr 1`。

**3. 从电脑连接：**

```sh
ssh -p 2222 admin@192.0.2.10
ssh -p 2222 admin@192.0.2.10 'cat /proc/version'      # 远程执行命令
scp -O -P 2222 fw.bin admin@192.0.2.10:/tmp/        # OpenSSH 9.0 及以后的客户端必须加 -O，原因见下文
scp -O -P 2222 admin@192.0.2.10:/var/log/app.log .   # 下载
ssh -p 2222 -N -L 8080:127.0.0.1:80 admin@192.0.2.10 # 本地端口转发：电脑上开 http://127.0.0.1:8080
```

启动时第一行日志会写明登录名对应的身份，例如
`Login 'admin' runs as uid 1000 gid 1000, home /data, shell /bin/sh`；如果是 root 启动，行尾会有 `(ROOT)`。

符号链接可以不建。`./dropbearmulti dropbear ...` 和 `./dropbearmulti dropbearkey ...` 直接就能用。
想用短命令名的话，也可以 `ln -s dropbearmulti dropbear`，`ln -s dropbearmulti dropbearkey`。
`dropbearkey` 用法：`./dropbearmulti dropbearkey -t ed25519 -f key`（生成），`-y -f key`（打印公钥和指纹）。

## 服务端选项

完整选项表（English）见文末“[Options](#options)”。新增：`-U 用户名`、`-P 明文密码`（推荐改用 `-H`）、`-H crypt 哈希`
（`$6$`/`$5$`）、`-k '公钥'`（可多次）、`-K authorized_keys 文件`（可多次）、`-s shell`、`-D home`。
被占用的上游字母改到：pid 文件 `-P file` → **`-x file`**；keepalive `-K secs` → **`-n secs`**；上游的 `-k`（禁止远程端口转发）→ **`-J`**。
本版本的服务端**没有编入远程端口转发**（`ssh -R` 一律拒绝），所以 `-k` 用来传公钥不会和它冲突；`-J` 只在自行打开远程转发编译选项时才有意义。`-j`（禁止本地端口转发 `-L`）保持上游含义。

## 运行环境说明

- **用户身份**：只有一个登录用户（`-U`），会话的 uid/gid 就是服务进程自己的 uid/gid（详见下面的“安全说明”）。
  用普通用户启动时，端口必须 ≥1024（例如 `-p 2222`），或者给本文件 `setcap cap_net_bind_service=+ep` 后用 22 端口（程序允许这一项 capability；这种用法尚未实测）。
- **/dev 最少需要**：`/dev/null`；`/dev/urandom`（3.4 内核没有 `getrandom()`，熵只能从它读，而且它必须是字符设备，
  否则程序拒绝启动）；交互式终端还需要 `/dev/ptmx` 和挂载好的 devpts（`/dev/pts`）。如果没有 devpts，
  `ssh -T`、远程执行命令和 scp 照样能用，交互式登录会提示 “PTY allocation request failed”，但仍可用（只是没有 tty）。
- **scp**：Dropbear 没有 sftp-server，而 OpenSSH 9.0 及以后的 `scp` 默认走 sftp 协议，所以客户端必须加 **`-O`**
  （旧协议）。WinSCP 要选 “SCP” 协议，不要选 SFTP。服务端收到 `scp -t/-f` 时，会直接调用本文件里内置的 scp，
  目标板上**不需要单独的 scp 程序**，也不依赖 PATH。旧 scp 协议会把远程路径交给远程 shell 解析，所以文件名里的
  空格要转义（`'host:dir/a\ b'`）。这个版本的 scp 只做被调用的那一端，在板子上主动发起 `scp` 需要
  `dropbearmulti-client`（见下文）。
- **端口转发**：支持 `-L`。目标地址只接受数字 IP（v4/v6）或 `localhost`，不做 DNS 解析，所以运行时不读
  `/etc/hosts`、`/etc/resolv.conf`。写主机名会被拒绝，客户端会看到 “host names are not supported by this build”。
  不支持 `-R`（远程转发）、agent 转发和 X11。
- **日志**：只写 stderr，格式 `[pid] 2026-10-26 15:28:48Z 消息`，时间是 UTC。要看日志就用 `-F -E` 前台运行，交给
  init/procd 管理；或者 `-F 2>>/tmp/dropbear.log &`。不加 -F 时会后台运行并关闭 stderr，日志就没了。
- **算法**（只有这些）：kex `curve25519-sha256`，主机/用户密钥 `ssh-ed25519`，加密 `chacha20-poly1305@openssh.com`。
  OpenSSH ≥ 6.5、PuTTY ≥ 0.68、WinSCP、Termius、JSch 0.2+ 都支持。RSA/ECDSA 用户密钥不能登录，请用 ed25519。
  OpenSSH 10.1 及以后会提示 “not using a post-quantum key exchange”，可以忽略，也可以换用 +pqkex 版本。
- **3.4 内核兼容**：程序会先尝试 3.4 之后才有的系统调用（`getrandom` 384、`statx` 397、`clock_gettime64` 403），
  拿到 ENOSYS 后自动退回旧调用（分别是 `/dev/urandom`、`fstatat64`、`clock_gettime`）。其余用到的系统调用都是 2.6 时代就有的。
  完整测试中实际出现的系统调用清单见本文末尾；在真实的 3.4.113 内核上也已完整跑过（见“验证结果”）。
- **加固方面的取舍**：为了缩小体积，默认版本没有栈保护（+ssp 版本有，多 4 KB）；不是 PIE；关闭了每个连接
  re-exec（它需要 `fexecve`，而 3.4 内核上 `fexecve` 依赖 /proc）。连接数和认证次数限制保持上游默认值：
  每个 IP 最多 5 个、总共最多 30 个未认证连接；每个连接最多认证 10 次；每次失败延迟 250–350 ms。
- **inetd 版本（+inetd）**：没有 syslog，日志写 stderr；如果 inetd 把 stderr 也接到了客户端 socket 上，程序会自动把
  stderr 改到 `/dev/null`，避免日志混进 SSH 数据流。

## 安全说明（审查后的行为）

- **只有一个用户，只有一个 uid**：只接受 `-U` 指定的登录名（其他名字连同正确密码/公钥一样被拒），会话永远以服务进程
  自己的 uid/gid 运行，没有任何切换用户的代码路径；万一会话身份和进程身份不一致，直接退出。
- **误用 root 启动**：
  - 不会扩大权限——会话就是 root，和服务进程本身相同；启动日志行尾带 `(ROOT)` 提醒。
  - 只放行 `-U` 指定的名字（`-w` 禁止 root 登录、`-g` 禁止 root 用密码登录仍然有效）。
  - 如果 `-U alice` 在 `/etc/passwd` 里存在且 uid 不是 0，拒绝启动：否则 alice 会拿到 root shell。
    正确做法是用 alice 身份启动服务（`su alice -c '...'`、`chpst -u alice`、procd 的 `user` 参数）。
  - `-U` 写一个 passwd 里不存在的名字（比如没有 /etc/passwd 的板子上 `-U admin`）是允许的，会话就是 root。
- **setuid/setgid 安装被拒绝**：真实 uid/gid 和有效 uid/gid 不一致时，所有子程序（dropbear/dropbearkey/scp）都直接退出
  （`Refusing to run setuid/setgid`）。否则任何本地用户都可以用自己的 `-P` 启动一个 root 会话。旧版本在 3.4 测试里
  确实能被 uid 1000 用 setuid 副本读到 root 的密钥文件，现在已修。非 root 运行时，除 `cap_net_bind_service` 外如果还带
  其他文件 capability（`setcap`）也拒绝运行。
- **密码比较**：`-P` 比较两边的 SHA-256 摘要（`constant_time_memcmp`，内容和长度都不泄露）；`-H` 先算出 crypt 结果，
  再做定长比较。空密码一律拒绝。失败延迟、每连接最多 10 次、未认证连接数上限沿用上游。
- **秘密不留痕**：`-P` 明文、`-H` 字面值、`DROPBEAR_PASSWORD` 在启动时从 argv/environ 原地抹掉（`/proc/PID/cmdline`
  和 `environ` 里看不到，3.4 实测），读文件用的缓冲区用完即清零，内存里只留 `-P` 的 SHA-256（或 `-H` 哈希本身）。
  启动前的极短时间内 `ps` 仍可能看到 `-P` 明文，所以正式使用请用 `-H` 或 `@文件`。
- **公钥**：只接受本程序支持的类型（ed25519）；带 options 的行一律拒绝（`-k` 启动时报错，`-K` 文件中的这类行被忽略并记日志），
  不会出现“限制被忽略、钥匙却生效”的情况。`-K` 文件及其所有上级目录都要通过属主/写权限检查。
- **随机数**：没有 `getrandom()` 的内核上，`/dev/urandom` 必须是字符设备，否则拒绝启动；也不会意外创建 `/dev/urandom` 普通文件。

## 第二个发布件：dropbearmulti-client（带 ssh 客户端）

`out/variants/dropbearmulti-client`，157,360 字节，静态链接（musl），平台要求和主发布件相同（ARMv7 Cortex-A7 硬浮点，Linux 3.4 及以上）。

```
sha256  8ee4a0fc1763e935cce43566c1b284b4eb09486a6b660303bf3af796bf8ae212   (out/variants/dropbearmulti-client.sha256)
```

它包含主发布件的全部内容（`dropbear`、`dropbearkey`、内置 `scp`，服务端行为和选项完全相同），另外加了：

- `dbclient`：ssh 客户端。`./dropbearmulti-client dbclient ...`，或者 `ln -s dropbearmulti-client ssh` 后直接 `./ssh ...`；
- `scp` 可以在板子上**主动发起**拷贝。scp 会直接调用本文件里内置的 dbclient，PATH 里不需要有 `dbclient` 或 `ssh`；
- 客户端的 `-L`（本地转发）和 `-R`（远程转发）；
- 主机名解析（libc DNS）：客户端要连主机名，所以这个文件会读 `/etc/hosts`、`/etc/resolv.conf`。
  服务端 `-p`/`-L` 也因此可以写主机名（主发布件只认数字地址）。

常用写法：

```sh
B=./dropbearmulti-client
$B dropbearkey -t ed25519 -f /data/id_ed25519            # 生成客户端密钥，公钥打印在屏幕上
$B dbclient -i /data/id_ed25519 admin@192.0.2.20 'uptime'          # 远程执行命令，退出码原样带回
$B dbclient -i /data/id_ed25519 -p 2222 admin@192.0.2.20           # 交互式登录（需要终端）
$B dbclient -i ~/.ssh/id_ed25519 user@host                           # ssh-keygen 生成的 OpenSSH 格式私钥也能直接用
$B dbclient -N -i /data/id_ed25519 -L 127.0.0.1:8080:127.0.0.1:80 admin@192.0.2.20   # 本地转发
$B dbclient -N -i /data/id_ed25519 -R 127.0.0.1:2200:127.0.0.1:22 me@server.example     # 远程转发（反向隧道）
$B scp -i /data/id_ed25519 -P 2222 fw.bin admin@192.0.2.20:/tmp/  # 板子主动上传
$B scp -i /data/id_ed25519 admin@192.0.2.20:/var/log/app.log /tmp/ # 板子主动下载
```

客户端行为说明：

- **私钥（`-i`）**：可以用 `dropbearkey` 生成的私钥，也可以直接用 `ssh-keygen` 生成的**没有口令的** OpenSSH 格式 ed25519 私钥
  （`-----BEGIN OPENSSH PRIVATE KEY-----`）。带口令的私钥不支持，会提示 “the key has a passphrase”，可以在电脑上对一份副本执行
  `ssh-keygen -p -N "" -f 副本` 去掉口令。RSA/ECDSA 私钥会提示 “only ed25519 keys are supported by this build”。
  不认识的文件会提示 “not a Dropbear or OpenSSH private key”。这几种情况客户端都不会退出，只是跳过这把钥匙，接着尝试别的认证方式。
  没给 `-i` 时，和上游一样尝试 `~/.ssh/id_dropbear`。
- **密码**：只从终端读（没有终端时直接失败并提示 “No terminal to read a password from (use -i keyfile)”，退出码 1）。
  在脚本里请用公钥。
- **known_hosts**：放在 `$HOME/.ssh/known_hosts`，`~/.ssh` 不存在时自动创建（0700）。板子上没有 `/etc/passwd` 或当前 uid 没有
  passwd 条目时，**只看环境变量 `$HOME`**；`$HOME` 也没有时，提示 “Failed to open $HOME (not set, no passwd entry)/.ssh/known_hosts”，
  不记录主机密钥，每次都要确认（或加 `-y`）。
  - 第一次连接会提示 “Do you want to continue connecting? (y/n)”；`-y` 表示自动接受未知主机密钥（不安全，只用于测试）。
  - 没有终端、标准输入又是空的（例如 `</dev/null`、cron、init 脚本）时，未知主机直接拒绝（“Didn't validate host key”，退出码 1）。
    上游在这种情况下会死循环占满 CPU，这里已修。脚本里第一次连接前，可以先把服务器公钥写进 known_hosts：
    `echo "192.0.2.20 $(cat ssh_host_ed25519_key.pub | cut -d' ' -f1,2)" >> $HOME/.ssh/known_hosts`。
  - 主机密钥变了会报 “host key mismatch” 并拒绝连接。注意 Dropbear 的 known_hosts **只按主机名/IP 记录，不区分端口**：
    同一个 IP 上不同端口跑着不同的 ssh 服务时，会被当成密钥变化（可以给其中一个用主机名或别的地址）。
- **默认登录名**：命令行没写 `user@` 或 `-l` 时，用当前 uid 的 passwd 条目；没有条目时依次用 `$USER`、`$LOGNAME`，
  uid 0 时用 `root`；都没有时提示 “failed to identify current user”，用 `unknown`。
- **退出码**：远程命令的退出码原样带回；认证失败、服务器在认证完成前断开、BatchMode 下需要密码等情况一律退出码 1
  （上游这几种情况会返回 0，脚本没法判断失败）。
- **端口转发**：`-L`、`-R` 都支持；连我们自己的服务端时 `-R` 会被拒（服务端没有编进远程转发），客户端提示
  “Remote TCP forward request failed”，会话本身不受影响。
- **不支持**：agent 转发（`-A`）、X11、`-J` 跳板、ProxyCommand、`~/.ssh/config`、sftp；算法同主发布件（只有 curve25519 /
  ssh-ed25519 / chacha20-poly1305，OpenSSH 6.5 及以后的服务端都支持）。

“String too long” 问题的原因：dbclient 把 `-i` 指定的每个文件都当成 Dropbear 自己的私钥格式解析。OpenSSH 格式的私钥是文本，
开头的 `----` 被当成 4 字节长度（0x2d2d2d2d），超过上限，于是直接 `Exited: String too long` 退出。这是上游 Dropbear 的行为，
不是裁剪配置或本补丁引起的：未打补丁、默认配置的上游 2026.94 dbclient（x86_64 本机编译）对同一把 ssh-keygen 私钥同样报
`Exited: String too long`。现在 `-i` 会先看文件格式：OpenSSH 格式交给一个只认无口令 ed25519、
每个长度都做边界检查的解析器；Dropbear 格式照旧；其他文件跳过并提示，不会让客户端退出。

## 体积（strip 后，字节）

| 版本 | 大小 | 相对 default |
|---|---:|---:|
| server-only（只有 dropbear） | 98,552 | −11,680 |
| server + dropbearkey | 100,728 | −9,504 |
| **default = server + dropbearkey + scp（交付版）** | **110,232** | 0 |
| default，去掉 `-L` 转发 | 109,240 | −992 |
| + aes128-ctr + hmac-sha2-256（给不支持 chacha20 的老客户端） | 117,600 | +7,368 |
| + mlkem768x25519 抗量子 kex | 130,992 | +20,760 |
| + inetd 模式 `-i` | 110,408 | +176 |
| + syslog（会连带拉进 localtime/strftime/时区代码） | 116,256 | +6,024 |
| + libc DNS 解析器（`-L`/`-p` 可以写主机名） | 121,192 | +10,960 |
| + `-fstack-protector-strong` | 114,304 | +4,072 |
| **+ dbclient（= 第二个发布件 dropbearmulti-client：客户端含 DNS、`-L`/`-R`；scp 可以主动发起）** | **157,360** | +47,128 |
| + dbclient + dropbearconvert | 169,648 | +59,416 |

`./build.sh --variants` 会把这些版本构建到 `out/variants/`（本仓库只发布 default 和 dropbearmulti-client 两个二进制）。

default 的代码和数据共约 109 KB，构成大致如下（审查前测得）：Dropbear 本身 59.6 KB，musl 37.5 KB，libtomcrypt 8.2 KB，
libtommath 1.2 KB，libgcc 1.6 KB；审查加固又给 Dropbear 部分加了约 1.3 KB。

体积是一步步压下来的。下表每一行都是实测值：

| 步骤 | 结果 | 节省 |
|---|---:|---:|
| 起点：上游源码加 localoptions，用 musl.cc 工具链（gcc 默认产出 static-pie，用的是 musl 1.2.2 预编译 ARM 模式的 libc.a） | 223,932 | |
| 关掉 PIE（`-fno-pie -no-pie`）；不用 libc 的 `crypt()` 分发器（它会把 DES、MD5、bcrypt 一起链进来）；不用 `sscanf`、`localtime`、`strftime`、`getgrnam`、`initgroups`，loginrec 不调用 `getpwnam` | 187,848 | −36,084 |
| scp 只保留被调用端：不用 `fnmatch`（它连带拉进宽字符表），不用 `strtod`（它连带拉进浮点解析），去掉客户端代码 | 159,416 | −28,432 |
| musl 1.2.6 从源码以 Thumb-2 `-Os` 重新编译 | 130,000 | −29,416 |
| 关掉 syslog（连带去掉时区代码） | 124,400 | −5,600 |
| 只解析数字地址，替换 libc 的 DNS 解析器（约 −11.5 KB）；SHA-crypt 改为基于 libtomcrypt 的自有实现；scp 进一步精简 | 108,840 | −15,560 |
| 安全审查加固：拒绝 setuid/多余 capability、root + 真实账号的 `-U` 拒绝启动、`-H` 抹掉 argv、空密码拒绝、`-k` 启动校验、`-K` 上级目录检查、相对路径换算、启动身份日志 | 110,128 | +1,288 |
| 修复 `-R` 生成主机密钥时使用已释放 `-r` 路径的 use-after-free | **110,232** | +104 |

再往下压，就只能拿掉功能了，比如 scp（约 9 KB）或 `-U` 默认值所依赖的 `getpwuid`（约 2.5 KB）。
LTO 试过，反而大了约 4 KB，所以没用。

## 构建

```sh
./build.sh                    # 交付版 → out/dropbearmulti + out/dropbearmulti.sha256
./build.sh --variants         # 再构建上表中的所有版本 → out/variants/（含 dropbearmulti-client）
./build.sh --client           # 只构建第二个发布件 → out/variants/dropbearmulti-client + .sha256
./build.sh --only "mine dropbear,dropbearkey,scp --disable-syslog -DEMB_LOCALFWD=0"
WORK=/path ./build.sh         # 下载、工具链和中间文件放在哪里（默认 ~/build-dropbear-armv7）
```

需要一台 x86_64 Linux 机器，装有 curl、tar、bzip2、make、patch、gpg（可选，用来校验签名）。`build.sh` 会：

1. 下载 Dropbear 2026.94，校验 sha256 和 GPG 签名（release key `F7347EF2EE2E07A267628CA944931494F29C6773`）；
2. 下载 musl.cc 的 `armv7l-linux-musleabihf-cross`（gcc 11.2.1），校验 musl.cc 公布的 sha512。
   这里只用它的 gcc/binutils；
3. 下载 musl 1.2.6，校验 sha256 和 GPG 签名（`836489290BB6B70F99FFDA0556BCDB593020450F`）；再下载
   CVE-2026-40200（qsort）、CVE-2026-6042（iconv）、CVE-2026-107891（regcomp）三个补丁，校验各自的 sha256；
   然后用 `-Os -mthumb -mcpu=cortex-a7` 编译 musl，装进工具链副本的 sysroot；
4. 对 Dropbear 打 `dropbear-2026.94-embedded.patch`，复制 `localoptions.h`，再 configure、make 和 strip。

构建结果可以复现：在另一个 WORK 目录从零构建（包括重新编译 musl），得到的 sha256 完全相同；审查后的版本在另一个构建目录重建一次，sha256 同样一致。
knob 定义在 `localoptions.h` 里（`EMB_LOCALFWD`、`EMB_AESCTR`、`EMB_PQ_KEX`、`EMB_INETD`、`EMB_NO_DNS`），
用 `-DEMB_xxx=0/1` 切换；`--disable-syslog` 等 configure 参数直接写在 `--only`/`--variants` 的参数里。

## 补丁内容（`dropbear-2026.94-embedded.patch`，22 个文件，约 +1360/−120；改动处都用 `EMB:` 注释标出）

- `svr-runopts.c`、`runopts.h`：新增 `-U -P -H -k -K -s -D`；`-P`/`-H` 的字面值在启动时被覆盖，`DROPBEAR_PASSWORD` 会被抹掉并 unset；
  启动时检查 `-H`（格式、rounds、空密码哈希）、`-k`（类型、不得带 options）、`-U`（字符集；root 运行时不得指向别的 uid 的真实账号）；
  用户名、home、shell 的默认值按上面的顺序决定（不需要有 passwd 条目）；`-r`/`-K`/`-x` 的相对路径换算成绝对路径；
  启动时记一行登录身份日志；记录本程序的绝对路径（依次用 `/proc/self/exe`、argv[0] 加 cwd、PATH 查找，所以即使没挂 /proc
  也能定位），供内置 scp 使用；pid 文件改为默认不写（`-x`），keepalive 改用 `-n`。
- `svr-auth.c`：用 `emb_fill_passwd()` 代替 `getpwnam`/`getspnam`；没有配置密码时不提供 password 认证；
  不检查 `/etc/shells`；`svr_switch_user()` 只检查会话 uid/gid 和服务进程一致，不调用 `initgroups`/`getgrnam`。
- `svr-authpasswd.c`：`-P` 模式下比较两边密码的 SHA-256 摘要，用 `constant_time_memcmp`，内容和长度都不会通过时间差泄露；
  `-H` 模式用自己实现的 SHA-crypt（$5$/$6$，按 Drepper 规范实现，基于 libtomcrypt）。已经和 glibc/libxcrypt 对比过
  414 组输入（含规范里的全部测试向量），结果完全一致；唯一的差别是 rounds<1000 时，规范和 musl 的做法是提升到 1000，
  libxcrypt 则直接拒绝，本实现与规范和 musl 一致（启动检查会拒绝这种哈希）。空密码直接拒绝。失败延迟和最大尝试次数仍走上游逻辑。
- `svr-authpubkey.c`：依次检查 `-k` 内联公钥、`-K` 文件（文件和所有上级目录都做属主/权限检查），都没配置时才用默认的
  `authorized_keys`；带 options 的公钥行一律拒绝。
- `dbmulti.c`：启动任何子程序前拒绝 setuid/setgid 和多余的 capability；`dropbearmulti --applet <名字> ...`，不管文件被改成
  什么名字，都能选中对应的子程序。
- `svr-chansession.c`：pty 的属主信息不再查 `getpwnam`；收到 `scp ...` 命令时改成执行本文件内置的 scp：
  `exec '<本文件>' --applet scp ...`（仍经用户 shell 解析参数，与上游执行 `scp` 的语义相同）。
- `sshpty.c`：不再调用 `getgrnam("tty")`。如果 devpts 已经给了 tty 组，就保持 0620；否则设为 0600。
  上游在这种情况下会退回 0622，即任何人都可写。
- `svr-kex.c`：`-R` 生成的主机密钥写进 `-r` 指定的文件（启动时保存路径副本；早先构建在这里用了上游启动时已释放的 `-r` 字符串，属 use-after-free，已修，回归测试见 `test-hostkey-rep.sh`）。
- `svr-main.c`：inetd 模式下 stderr 是 socket 时改到 `/dev/null`；pid 文件可选。
- `dbrandom.c`：不会再用 O_CREAT 去写 `/dev/urandom`；在没有 `getrandom()` 的内核上，要求 `/dev/urandom` 必须是字符设备。
- `netio.c`、`includes.h`：`EMB_NO_DNS` 打开时，用只认数字地址和 `localhost` 的 `getaddrinfo`/`getnameinfo` 替换 libc 的版本。
- `scp.c`：`EMB_SCP_SERVER_ONLY`（没编译 dbclient 时自动打开）；`-l` 改用 `strtoul`；不调用 `fnmatch`。
  编译了 dbclient 时，scp 主动发起拷贝用的是本文件内置的 dbclient（以 argv[0]=`dbclient` 执行本文件），不依赖 PATH。
- 只影响客户端（`cli-*.c`，主发布件里不编译这些文件，主发布件逐字节不变）：
  `cli-runopts.c`：`-i` 支持无口令的 OpenSSH 格式 ed25519 私钥（带边界检查的解析器），不认识的文件跳过并说明原因，
  不再 `Exited: String too long`；没有 passwd 条目时默认登录名取 `$USER`/`$LOGNAME`（uid 0 用 `root`）。
  `cli-kex.c`：没有终端且 stdin 已到 EOF 时，主机密钥确认不再死循环；`$HOME` 和 passwd 都没有时提示说清楚原因。
  `cli-auth.c`、`cli-session.c`：读不到密码、BatchMode 需要密码、认证完成前连接被断开，退出码由 0 改为 1。
- `localoptions.h` / `build.sh`：新开关 `EMB_CLIENT`（构建 dbclient 时由 build.sh 自动设为 1），打开客户端 `-L`/`-R`；
  不带 dbclient 的版本这些宏不变。
- `svr-session.c`：stderr 日志的时间改为 UTC，用 `gmtime_r` 生成；`dropbearkey.c`：不用 `sscanf`；`loginrec.c`：不再调用 `getpwnam`。

## 验证结果

在 x86_64 主机上用 qemu-arm（用户态）跑本目录下的脚本，客户端是 OpenSSH 8.9：

- `test-qemu.sh`，39 项全部通过（安全审查后用最终二进制重跑，结果相同）：
  - 认证：-P、-P @file、DROPBEAR_PASSWORD（且不会泄露到会话环境）、-H $6$/$5$/rounds、-H 拒绝 $1$、-P 与 -H 同时给出时拒绝启动；
    错误密码、密码前缀、更长的密码、其他用户名都被拒绝，失败延迟 ≥250 ms；
  - 公钥：-k、-K、默认 authorized_keys；-K 文件 world-writable 时拒绝；带 options 的公钥行拒绝；
  - 会话：pty 分配正常（`crw--w---- tty`）；`-R -r` 生成主机密钥；
  - scp -O：上传、下载、-r，并确认服务端确实改走了内置 applet；
  - `-L`：转发到 127.0.0.1 和 localhost 正常，转发到主机名时被干净地拒绝；
  - 监听：通配地址、`[::1]` IPv6；
  - 协商结果：curve25519-sha256 / ssh-ed25519 / chacha20-poly1305 (MAC implicit)。
- `test-emptyroot.sh`，3 项全部通过（安全审查后重跑，结果相同）。用 rootless podman 跑一个镜像，里面只有本文件、一个静态 `/bin/sh` 和 `/dev`。
  podman 自己只会加 /proc、/sys、/etc/hostname；镜像里没有 passwd/group/shadow，也没有任何库，进程 uid 4321 也没有 passwd 条目。
  默认用户 `root`、home `/` 的推导正确；公钥登录、密码登录、scp 上传和下载都通过。
- 用 seccomp 让 `getrandom` 返回 ENOSYS（模拟 3.4 内核）：程序退回读 `/dev/urandom`，dropbearkey 和服务端都正常。
- 完整测试中实际出现的系统调用：read _newselect close open writev fcntl64 rt_sigprocmask mmap2 write setsockopt
  munmap getpid rt_sigaction geteuid32 pipe wait4 fork getpeername set_tid_address sigreturn getrandom(*) exit_group dup2
  getegid32 setsid brk accept prlimit64 socket getsockname statx(*) getuid32 connect access chdir readlink listen bind
  ioctl shutdown umask setresuid32 setresgid32 nanosleep fsync getgid32 ftruncate64 chmod unlink uname mkdir _llseek
  link getsockopt chown32 clock_gettime64(*)。标 (*) 的是 3.4 之后才加入的调用，失败后都会自动退回旧调用。
- `readelf -A`：`Tag_CPU_arch: v7`、profile Application、`Tag_THUMB_ISA_use: Thumb-2`、`Tag_FP_arch: VFPv4`、
  `Tag_Advanced_SIMD_arch: NEONv1 with Fused-MAC`、`Tag_ABI_VFP_args: VFP registers`（即硬浮点 ABI）、
  `Tag_DIV_use`（硬件除法）、`Tag_Virtualization_use`。其中 `Tag_CPU_name` 显示的是 `"7-A"`，不是 `"Cortex-A7"`。
  原因是 gcc ≥ 8 生成汇编时，在 `.cpu cortex-a7` 后面又输出了 `.arch armv7-a` 和 `.arch_extension virt/idiv/sec/mp`，
  gas 最终记录的是架构名。这组扩展正好就是 Cortex-A7 的特性集。
- `test-matrix-user.sh`（独立验收矩阵，qemu-arm 用户态，非 root 用户，客户端 OpenSSH 8.9），49 项全部通过。
  严格按 `dropbear -R -F -E -p 2222 -U <用户> -H <hash>` 启动，**不给 -s/-D**，登录名在 /etc/passwd 里不存在：
  - 认证：-H $6$ / $5$ 登录；错误密码、大小写不同、空密码被拒；用户名 root、本机真实用户名、带后缀的用户名都被拒；
    -H 的 rounds=500、截断的 hash、-P '' 都在启动时拒绝；-P 带空格/引号/$ 的密码正常；
    同一连接连续输错密码，第 10 次后服务端断开（日志 `Max auth tries reached`），每次失败有延迟；
  - 公钥：-k 两次（两把都能登），-K 文件（含注释、空行），运行中往 -K 文件追加公钥后立刻生效；只给 -k 时不提供密码认证；
  - 会话：USER/LOGNAME/HOME/SHELL/PWD 由 getuid()、`$HOME`、`$SHELL` 推导正确；命令退出码和 stderr 回传；
    1 MiB stdin 透传校验一致；pty 交互：`/dev/pts/N`、窗口大小 37x113、TERM 透传、Ctrl-C 能中断前台 `sleep`、退出码回传；
  - 主机密钥：`-R -r 文件` 生成 0600 的密钥；重启后复用，客户端 `StrictHostKeyChecking=yes` 通过；换 -r 文件则客户端报主机密钥变化；
  - `-L`：1 MiB 经隧道校验一致，4 个并发通道都正确；`ssh -R`（远程转发）被拒（本版本没编进去）；
  - scp -O 上传/下载 1 MiB；`-p 2222` 通配监听；服务端日志里不出现密码明文；
  - 安全审查新增 9 项：空密码的 `-H` 哈希、带 `command=` 的 `-k`、`ssh-rsa` 的 `-k`、含 `;` 或以 `-` 开头的 `-U` 都在启动时拒绝；
    启动日志写明登录名/uid/gid/home；`-K` 文件所在目录 group 可写时拒绝，直接放在 sticky 的 `/tmp` 下可用；
    后台模式下相对路径的 `-r`/`-x`/`-K` 按启动目录生效。
- `test-kernel34.sh` + `test-kernel34-guest.sh`：**真实的 Linux 3.4.113 内核**（qemu-system-arm vexpress-a15，
  `-cpu cortex-a7`，TCG），根文件系统是 `qemu34/initramfs-nopasswd`，**没有 /etc/passwd、/etc/group、/etc/shadow**，
  服务以 uid/gid 1000:1000 运行（同样没有 passwd 条目），宿主机的 OpenSSH 8.9 通过 qemu 端口转发连接。33 项全部通过：
  - 3.4 上没有 getrandom：dropbearkey 和服务端都退回 `/dev/urandom` 正常工作；把 `/dev/urandom` 换成普通文件时拒绝启动
    （`/dev/urandom is missing or not a character device`），绑到 `/dev/null`（读到 EOF）时也拒绝（`Failure reading random device`）；
  - -H @file、-P @file、-k、-K 登录；错误密码/错误用户/未列出的公钥被拒，并在服务端日志里确认是真正的认证拒绝；
  - 命令退出码；pty 交互（`crw--w---- 1000 5`，即 devpts 的 tty 组 + 0620）；`-L` 转发到客户机 busybox httpd，1 MiB 校验一致；
    scp -O 上传/下载（客户机上没有 scp 程序，走内置 applet）；
  - `-x` pid 文件；杀掉监听进程后重启，主机密钥不变（`StrictHostKeyChecking=yes` 通过）；
  - 不加 `-F` 的后台模式可登录；`-P` 明文和 `DROPBEAR_PASSWORD` 都已从 `/proc/<pid>/cmdline`、`/proc/<pid>/environ` 抹掉，也不进会话环境；
  - 安全审查新增 8 项：root 拥有的 setuid 副本、setgid 副本由 uid 1000 运行时都拒绝运行；root 启动且 `-U alice`（passwd 里 uid 1000）
    拒绝启动；root 启动、`-U admin`（无 passwd 条目）、后台模式、`-H` 字面值、相对 `-r ekey -x e.pid`：会话 uid 0（与服务进程相同），
    其他用户名被拒，密钥和 pid 文件落在启动目录而不是 `/`，`/proc/<pid>/cmdline` 里没有哈希，启动日志带 `(ROOT)`；
  - 协商结果 curve25519-sha256 / ssh-ed25519 / chacha20-poly1305；串口上没有 SIGILL、SIGSYS、oops 或段错误。
- **测试校准**：把审查前的二进制（sha256 `ed5ec8f1…7c9c7d`）放进同样的两套测试，新增的检查分别失败 8 项和 6 项，其余全部通过，
  说明新增测试确实能区分修复前后。其中 setuid 一项在旧版本上真实复现了提权：uid 1000 通过 setuid-root 副本读出了 root 的 0600 密钥文件。
- 系统调用审查（2026-10-26 复核）：
  - 动态：`test-qemu.sh` 和 `test-matrix-user.sh` 在 `qemu-arm -strace` 下完整跑一遍，共出现 56 种系统调用。按 ARM 编号，
    3.4 内核最后一个是 377（`process_vm_writev`），超过 377 的只有 `getrandom`(384)、`statx`(397)、`clock_gettime64`(403)；
  - 静态：反汇编未 strip 的同一构建（strip 后 sha256 与交付件一致），所有 `svc` 处装入 r7 的立即数里超过 377 的只有
    `utimensat_time64`(412，scp -p 设置时间时，musl 只在时间超出 32 位时才用，否则直接用 `utimensat` 348，2.6.22 起就有)；
    经 `__syscall_cp` 间接发起的调用来自 accept/close/connect/fcntl/fsync/getrandom/open/read/select/sendmsg/
    nanosleep/futex/waitpid/write/writev，其中 select 和 nanosleep 的 time64 版本同样只在超时超出 32 位时才用；
  - 审查后新增的唯一系统调用是 `capget`(184，2.2 起就有)，启动时调用一次；
  - musl 1.2.6 的退回逻辑（源码确认）：`statx` 遇 ENOSYS 退回 `fstatat64/fstat64`；`clock_gettime64` 遇 ENOSYS
    退回 `clock_gettime`(263)（3.4 的 ARM 没有 vDSO，所以每次都走系统调用）；`getrandom` 由 dropbear 退回 `/dev/urandom`。
    以上在真实 3.4 内核上的功能测试里都已实际走到。
- **dropbearmulti-client（第二个发布件）**，客户端是本文件里的 dbclient：
  - `test-client.sh`（qemu-arm 用户态，28 项全部通过）。客户端以 **uid 4321 运行，这个 uid 没有 passwd 条目**，环境里只有 PATH 和 HOME。
    客户端这一侧放在 rootless 的 user+mount 命名空间里，并在命名空间内注册 qemu-arm 的 binfmt_misc（Linux ≥ 6.7 支持），
    所以 ARM 程序可以像在板子上一样 exec 自己（scp → 内置 dbclient、服务端 → 内置 scp），不需要包装脚本。
    对端一是宿主机自带的 **OpenSSH 8.9p1 sshd**（`/usr/sbin/sshd`，不用 root：在 rootless 命名空间里启动，临时用户 pwuser，
    假的 passwd/shadow 只挂在那个命名空间里，见 `test-ossh-harness.sh`），对端二是我们的服务端（主发布件，以及本文件自己的 dropbear）：
    - OpenSSH：`-i` OpenSSH 格式私钥登录（原来的 “String too long”）；未知主机 + 无终端 + stdin EOF 立即拒绝且不写 known_hosts；
      终端里回答 y + 密码登录；known_hosts 建在 `$HOME/.ssh`（0700）；错误密码被拒且退出码 1；dropbearkey 私钥登录、已知主机静默通过；
      远程退出码 7 和 stderr 带回；1 MiB stdin 校验一致；`-t` 交互式 pty（`/dev/pts/0`）；带口令/RSA/乱码私钥分别给出明确提示且不崩；
      `$USER` 作默认登录名；没有 `$HOME` 时提示清楚且 `-y` 可连；`-L` 1 MiB + 4 路并发校验一致；`-R`（sshd 开的监听）1 MiB 校验一致；
      `PATH=/nonexistent` 下 scp 上传/下载 1 MiB 一致；
    - 我们的服务端：127.0.0.1 的主机密钥与 known_hosts 不符时报 mismatch 并拒绝；`localhost`（本文件带 DNS）回答 y + 密码登录；
      两种私钥登录、退出码 5；交互式 pty；`-L` 1 MiB 一致；`-R` 被服务端拒绝、会话照常；scp 双向（内置 dbclient ↔ 服务端内置 scp）；
      本文件自己的 dropbear + dbclient 互连。
  - `test-client-kernel34.sh` + `test-client-kernel34-guest.sh`：**真实的 Linux 3.4.113**（qemu-system-arm vexpress-a15，`-cpu cortex-a7`），
    客户机没有 /etc/passwd，客户端以 uid 1000（无 passwd 条目）运行，经 qemu user-net 连宿主机的 OpenSSH sshd（10.0.2.2），
    也连客户机里本文件自己的服务端。21 项全部通过：OpenSSH 格式私钥登录、无终端未知主机立即拒绝、主机密钥确认 + 密码登录
    （busybox `script` 提供终端）、known_hosts 建在 `$HOME/.ssh`、退出码、带口令私钥提示、`$USER` 默认名、无 `$HOME`、交互式 pty、
    `-L`（取宿主机文件）和 `-R`（宿主机 sshd 的监听绕回客户机 httpd）各 1 MiB 校验一致、`PATH=/nonexistent` 下 scp 与宿主机/自己的服务端双向拷贝；
    宿主机 sshd 日志确认了密码登录；串口上没有 SIGILL/SIGSYS/oops/段错误。
  - **测试校准**：同一套 `test-client.sh` 跑修复前的 +dbclient（`c3727b1f…`）：28 项里 20 项失败。直接相关的有：`-i` OpenSSH 私钥报
    `String too long`；无终端未知主机卡死到超时（死循环）；错误密码退出码 0；`-L`/`-R` 没有编进去；scp 找不到 `dbclient`；
    默认登录名是 `unknown`。其余失败是这些问题的连带结果（后续用例用的是 OpenSSH 私钥）。
- **修复后重新构建**：上面的结果之后又修复了 `-R` 主机密钥生成的 use-after-free，所有版本重新构建，当前主发布件 sha256 为
  `0322fc4a…1cddc5b2`、dropbearmulti-client 为 `8ee4a0fc…bf8ae212`。各测试脚本已加入这个问题的回归用例（`test-hostkey-rep.sh`），
  但并非每一项都在最终构建上重跑过，见下面“已知限制”。

## 已知限制

- 这是开发/测试用工具。只在 QEMU 中测试过（qemu-arm 用户态；qemu-system-arm 跑 Linux 3.4.113 客户机，`-cpu cortex-a7`/`cortex-a15`），
  以及在一块 RK3588 板子的 AArch32 兼容模式下运行过（用的是较早的构建）。**没有在真实的 Cortex-A7 板子上测试过。**
- QEMU 10.2 在 `-M vexpress-a15` 上需要用 `-cpu cortex-a15`（`run-qemu.sh` 里 `CPU=cortex-a15`）。
- Android 上以 uid shell 运行、放在 `/data/local/tmp` 下时，`-K` 文件的上级目录属主检查通不过，请改用 `-k '公钥'`。
- dbclient 的 `-i` 只接受 Dropbear 格式私钥，或**没有口令的** OpenSSH 格式 ed25519 私钥。
- Linux 3.4 客户机上的客户端 `-L` 测试没有在最终构建上重跑。

---

## English

### What it is

A patched **Dropbear 2026.94** built as **one static musl executable** for **ARMv7 Cortex-A7, hard-float**
(`-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -mthumb`, OpenWrt `arm_cortex-a7_neon-vfpv4`), Linux **3.4+**.
It runs as the current user and needs **no system users**: the login name, password / crypt hash and public keys come
from the command line. No shared libraries, no `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/shells`, PAM,
syslog, config files or a separate `scp` program are needed. This is a developer/test tool; see *Known limitations*.

| Release asset | Size (bytes) | Contents | sha256 |
|---|---:|---|---|
| `dropbearmulti` | 110,232 | `dropbear` server + `dropbearkey` + `scp` (server side only) | `0322fc4aad0a8d88c243c0f0f16fccb400e171256eca458a1227a3301cddc5b2` |
| `dropbearmulti-client` | 157,360 | all of the above + `dbclient` (ssh client); `scp` can initiate copies | `8ee4a0fc1763e935cce43566c1b284b4eb09486a6b660303bf3af796bf8ae212` |

Algorithms: kex `curve25519-sha256`, host/user keys `ssh-ed25519`, cipher `chacha20-poly1305@openssh.com`
(OpenSSH >= 6.5, PuTTY >= 0.68). RSA/ECDSA user keys are not supported.

### Quick start

```sh
# on your PC: make a SHA-512 crypt hash (keep the plaintext off the board's command line)
openssl passwd -6

# on the board (non-root, port >= 1024); -R creates the host key in the -r file on first connection
chmod +x dropbearmulti
./dropbearmulti dropbear -F -E -R -r /data/ssh_host_ed25519 -p 2222 -U admin -H '$6$salt$hash...'
./dropbearmulti dropbear -F -E -R -r /data/ssh_host_ed25519 -p 2222 \
    -U admin -H @/data/admin.hash -K /data/authorized_keys          # hash and keys from files
./dropbearmulti dropbear -F -E -R -r /data/ssh_host_ed25519 -p 2222 \
    -U admin -k 'ssh-ed25519 AAAAC3Nza... me@pc'                    # public key only
./dropbearmulti dropbearkey -t ed25519 -f key                       # generate a key

# from your PC
ssh -p 2222 admin@192.0.2.10
scp -O -P 2222 fw.bin admin@192.0.2.10:/tmp/                        # -O is required, see below
ssh -p 2222 -N -L 8080:127.0.0.1:80 admin@192.0.2.10

# client build, on the board
./dropbearmulti-client dbclient -i /data/id_ed25519 admin@192.0.2.20 'uptime'
./dropbearmulti-client scp -i /data/id_ed25519 -P 2222 fw.bin admin@192.0.2.20:/tmp/
```

### Options

Single-user options (new in this build):

| option | meaning |
|---|---|
| `-U user` | The only login name accepted. Default: name of the current uid from `/etc/passwd` if such an entry exists, otherwise `root`. Allowed characters: `A-Z a-z 0-9 . _ - @`, must not start with `-`. When the server runs as **root** and `/etc/passwd` maps `user` to a different uid, startup is refused (it would hand that user a root shell). |
| `-P password` | Plaintext password. Visible in `ps` / `/proc/PID/cmdline` until startup, then the argument is overwritten in place. Prefer `-H`. `-P @/path/file` reads it from a file (one line, trailing newline stripped; a warning is logged if the file is group/world-readable). The env var `DROPBEAR_PASSWORD` (also `@file`) is used if neither `-P` nor `-H` is given; it is always wiped and removed from the environment, so login sessions never see it. Empty passwords are refused. A password that itself starts with `@` must be given through a file. Only its SHA-256 is kept in memory. |
| `-H hash` | crypt(3) hash: `$6$…` (SHA-512) or `$5$…` (SHA-256), `rounds=` 1000…9999999 supported. `-H @/path/file` reads it from a file. A literal `-H` value is wiped from `/proc/PID/cmdline` at startup (a hash can still be brute-forced offline). Refused at startup: other formats (DES, `$1$` MD5, bcrypt), malformed/truncated hashes, `rounds` < 1000, and the hash of an empty password. |
| `-k 'pubkey'` | Accept this public key, given inline as one plain `authorized_keys` line (`ssh-ed25519 AAAA… comment`). Repeatable, up to 16 keys. Checked at startup: the line must start with a key type built into this binary (only `ssh-ed25519`); lines with options (`command=…`) are refused. |
| `-K file` | Accept keys from this `authorized_keys` file, re-read on every login. Repeatable, up to 4 files. The file **and every directory above it** must be owned by you or root and must not be group/world-writable (a sticky directory owned by root or you, like `/tmp`, is fine as a parent). Lines with options are ignored (logged). |
| `-s shell` | Login shell. Default order: the passwd entry for our uid, then `$SHELL`, then `/bin/sh`. |
| `-D homedir` | Home directory, used for `$HOME` and as the working directory. Default order: the passwd entry, then `$HOME`, then `/`. |

- If neither `-P` nor `-H` is given, password logins are off. The server does not offer the password method, and requests for it are rejected.
- If neither `-k` nor `-K` is given, `<home>/.ssh/authorized_keys` is used (upstream behaviour, with permission checks).
- `authorized_keys` options (`command=`, `from=`, `no-pty`…) are compiled out. A key line that carries options is **refused** rather than accepted without its restrictions.
- Relative paths given to `-r`, `-K` and `-x` are resolved against the start directory (background mode `chdir`s to `/`).
- `-B` (blank passwords) has no effect: an empty password never logs in.

Kept from upstream: `-p [addr:]port` (repeatable, up to 10; IPv6 as `[::1]:22`), `-F` foreground, `-E` (accepted; logging always goes to stderr),
`-R` create the host key on first connection, `-r keyfile` host key, `-b banner`, `-w` no root logins, `-g` no root password logins,
`-t` require password **and** key, `-T n` maximum auth tries, `-j` disable `-L` forwarding, `-c cmd` forced command,
`-l iface`, `-W`, `-I idle`, `-M maxtime`, `-z`, `-e`, `-Q`, `-V`, `-h`.

Changed letters (they were taken by the new options): pid file `-P file` → **`-x file`** (default: no pid file); upstream `-k` (disable remote port forwarding) → **`-J`** — the default server build has remote forwarding compiled out (`ssh -R` is always refused), so `-k` is free for inline public keys; `-j` (disable local `-L` forwarding) keeps its upstream meaning;
keepalive `-K secs` → **`-n secs`**; authorized_keys directory `-D dir` → replaced by `-K file`;
"disable password logins" `-s` → simply omit `-P`/`-H`.

With `-r FILE -R`, the key is created in `FILE`. Upstream would always write to `/etc/dropbear/...`, which a non-root user can't do.

### Build

```sh
./build.sh                    # default -> out/dropbearmulti
./build.sh --client           # -> out/variants/dropbearmulti-client
./build.sh --variants         # all size variants -> out/variants/
WORK=/path ./build.sh         # download/toolchain/work dir (default ~/build-dropbear-armv7)
```

Needs an x86_64 Linux host with curl, tar, bzip2, make, patch (gpg optional). `build.sh` downloads and verifies
Dropbear 2026.94 (sha256 + GPG), the musl.cc `armv7l-linux-musleabihf-cross` toolchain (sha512), and musl 1.2.6
(sha256 + GPG) plus three upstream CVE patches; rebuilds musl with `-Os -mthumb -mcpu=cortex-a7`; applies
`dropbear-2026.94-embedded.patch` and `localoptions.h`. Builds are reproducible (same sha256 from a clean WORK dir).

### Security notes

- **`-P` plaintext**: the argument (and `DROPBEAR_PASSWORD`) is wiped from argv/environ at startup, but it can be
  visible in `ps` for a short moment before that. **Prefer `-H` (crypt hash) or `@file`.** Empty passwords are refused.
- **setuid/setgid is refused**: if real and effective uid/gid differ, every applet exits
  (`Refusing to run setuid/setgid`). Extra file capabilities other than `cap_net_bind_service` are refused too.
- Single user, single uid: sessions always run with the server's own uid/gid; there is no user switching.
  Started as root with `-U alice` where `/etc/passwd` maps alice to a non-zero uid, startup is refused.
- `authorized_keys` lines with options (`command=`, `from=`, ...) are refused, never accepted without their restrictions.
  `-K` files and every parent directory must not be group/world-writable.
- **scp clients need `scp -O`**: Dropbear has no sftp-server and OpenSSH >= 9.0 `scp` uses SFTP by default.
  WinSCP: choose the SCP protocol. The server runs the built-in scp applet, so no `scp` binary is needed on the board.
- The default build resolves numeric addresses and `localhost` only (no DNS); `-L` is supported, `-R`, agent and X11
  forwarding are not. Logs go to stderr only (no syslog): run with `-F -E` under init/procd.

### Known limitations

- Only tested in QEMU (qemu-arm user mode; qemu-system-arm with a Linux 3.4.113 guest, `-cpu cortex-a7` / `cortex-a15`)
  and on an RK3588 board in AArch32 compat mode (with an earlier build). **Not tested on a real Cortex-A7 board.**
- QEMU 10.2 needs `-cpu cortex-a15` on `-M vexpress-a15` (`CPU=cortex-a15 ./qemu34/run-qemu.sh`).
- On Android as uid `shell` under `/data/local/tmp`, use `-k 'pubkey'` instead of `-K file` (the parent-directory
  ownership check fails there).
- `dbclient -i` needs a Dropbear-format key or an **unencrypted** OpenSSH-format ed25519 key.
- The binaries were rebuilt after a use-after-free fix in `-R` host-key generation; not every test was re-run on the
  final build. In particular, the Linux 3.4 guest client `-L` test was not re-run.

### License

Dropbear is under an MIT-style license; the patch and scripts here are under the same license. See `LICENSE`.
