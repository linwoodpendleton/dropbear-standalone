#!/usr/bin/env bash
# Acceptance matrix on a REAL Linux 3.4.113 kernel: qemu-system-arm vexpress-a15
# with -cpu cortex-a7 (cortex-a15 on QEMU >= 10, see CPU below) (TCG), base initramfs WITHOUT /etc/passwd (qemu34/),
# servers running as uid 1000 (no passwd entry); driven from the host with the
# stock OpenSSH client through qemu user-net port forwards.
#
# Usage: ./test-kernel34.sh [binary]
#   QEMU_SYSTEM="podman run --rm -i --network=host -v ...:Z localhost/qemu-arm:24.04 qemu-system-arm"
#   (default: qemu-system-arm from PATH; if absent, the localhost/qemu-arm podman image)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-hostkey-rep.sh"
BIN="$(readlink -f "${1:-$HERE/out/dropbearmulti}")"
Q34="$HERE/qemu34"
HP=${HP:-22220}          # host ports HP+2 .. HP+8 -> guest 2222..2228, HP+9 for -L
T="$(mktemp -d /tmp/db34.XXXXXX)"
PASS=0; FAIL=0; RES=()
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); RES+=("PASS|$*"); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); RES+=("FAIL|$*"); }

ssh-keygen -q -t ed25519 -N '' -C k34a -f "$T/id1"
ssh-keygen -q -t ed25519 -N '' -C k34b -f "$T/id2"
ssh-keygen -q -t ed25519 -N '' -C k34c -f "$T/id3"
openssl passwd -6 -salt 'K34salt' 'Hash pw 34' > "$T/h6"
printf 'File pw 34\n' > "$T/pw"
mkdir -p "$T/data"
cp "$BIN" "$T/data/dropbearmulti"; cp "$T/h6" "$T/pw" "$T/id1.pub" "$T/id2.pub" "$T/data/"
cp "$HERE/test-kernel34-guest.sh" "$T/data/test.sh"
chmod 0755 "$T/data" "$T/data/dropbearmulti" "$T/data/test.sh"; chmod 0644 "$T/data"/{h6,pw,id1.pub,id2.pub}
( cd "$T" && find data | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) | gzip -9n > "$T/data.cpio.gz"
cat "$Q34/initramfs-nopasswd.cpio.gz" "$T/data.cpio.gz" > "$T/initrd.cpio.gz"

FWD="user"; for i in 2 3 4 5 6 7 8; do FWD="$FWD,hostfwd=tcp:127.0.0.1:$((HP+i))-:222$i"; done
# CPU: QEMU >= 10 only accepts -cpu cortex-a15 on -M vexpress-a15 ("Invalid CPU
# model: cortex-a7"); older versions also take cortex-a7, the target core.
# Probe it (an accepted CPU gets as far as loading the nonexistent kernel),
# unless CPU=... is given.
if command -v qemu-system-arm >/dev/null; then QSYS=(qemu-system-arm)
else QSYS=(podman run --rm -i --network=none localhost/qemu-arm:24.04 qemu-system-arm); fi
if [ -z "${CPU:-}" ]; then
	CPU=cortex-a15
	"${QSYS[@]}" -M vexpress-a15 -cpu cortex-a7 -nodefaults -display none -monitor none -serial none -audio none \
		-kernel /nonexistent-cpu-probe </dev/null 2>&1 | grep -q "could not load kernel" && CPU=cortex-a7
fi
QARGS=(-M vexpress-a15 -cpu "$CPU" -smp 2 -m 256 -kernel "$Q34/zImage" -dtb "$Q34/vexpress-v2p-ca15-tc1.dtb"
	-initrd "$T/initrd.cpio.gz" -append "console=ttyAMA0 rdinit=/init" -nic "$FWD" -audio none
	-display none -monitor none -serial "file:$T/serial.log")
if command -v qemu-system-arm >/dev/null; then
	qemu-system-arm "${QARGS[@]}" </dev/null >/dev/null 2>"$T/qemu.err" &
	VM=$!; VMKILL="kill $VM"
else
	podman run -d --name db34-$$ --network=host --userns=keep-id -v "$T:$T:Z" -v "$Q34:$Q34:ro,Z" \
		localhost/qemu-arm:24.04 qemu-system-arm "${QARGS[@]}" >/dev/null || { echo "cannot start VM"; exit 1; }
	VMKILL="podman rm -f db34-$$"
fi
trap '$VMKILL >/dev/null 2>&1; cp "$T/serial.log" "${SERIAL_KEEP:-/dev/null}" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 240); do grep -q "M34-READY" "$T/serial.log" 2>/dev/null && break; sleep 1; done
grep -q "M34-READY" "$T/serial.log" || { echo "VM did not get ready"; tail -30 "$T/serial.log"; exit 1; }
echo "== guest setup log:"; grep -aE "^M34|NK34-INIT: (kernel|NO|/etc)" "$T/serial.log" | sed 's/^/  /'

KH="$T/kh"
SSHO=(-F /dev/null -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=60)
cat > "$T/askpass" <<'EOF'
#!/bin/sh
cat "$ASKPASS_FILE"
EOF
chmod 755 "$T/askpass"
sshpw() { # port password user args...
	local p="$1" pw="$2" u="$3"; shift 3
	printf '%s\n' "$pw" > "$T/apw"
	ASKPASS_FILE="$T/apw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHO[@]}" -p "$p" \
		-o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "$u@127.0.0.1" "$@" </dev/null
}
sshkey() { local p="$1" k="$2" u="$3"; shift 3
	ssh "${SSHO[@]}" -p "$p" -o BatchMode=yes -o IdentitiesOnly=yes -i "$k" "$u@127.0.0.1" "$@" </dev/null; }
A=$((HP+2)); B=$((HP+3)); C=$((HP+4)); D=$((HP+5)); E=$((HP+6))

g=$(grep -a "^M34: kernel" "$T/serial.log")
echo "$g" | grep -q "kernel 3.4.113 armv7l" && ok "guest kernel: $(echo "$g" | cut -d' ' -f2-5)" || bad "kernel: $g"
grep -aq "^M34: ls: /etc/passwd: No such file" "$T/serial.log" && grep -aq "^M34: ls: /etc/group: No such file" "$T/serial.log" \
	&& ok "guest has no /etc/passwd, /etc/group, /etc/shadow" || bad "guest /etc not bare"
grep -aq "^M34: dropbearkey(root) ok" "$T/serial.log" && ok "3.4: dropbearkey ed25519 (getrandom ENOSYS -> /dev/urandom)" || bad "dropbearkey on 3.4"
l=$(grep -a "^M34: urandom=regular-file" "$T/serial.log")
echo "$l" | grep -q "rc=1 .*not a character device" && ok "3.4: /dev/urandom replaced by regular file -> refuses ($(echo "$l" | sed 's/.*msg=//'))" || bad "fake urandom: $l"
l=$(grep -a "^M34: urandom=/dev/null" "$T/serial.log")
echo "$l" | grep -q "rc=0" && bad "3.4: /dev/urandom=/dev/null (empty char dev) accepted: $l" || ok "3.4: /dev/urandom bound to /dev/null (EOF) -> refuses ($(echo "$l" | sed 's/.*msg=//'))"

# --- A: -H @file
out=$(sshpw $A 'Hash pw 34' tester 'echo "OK $(id) USER=$USER HOME=$HOME SHELL=$SHELL PWD=$PWD"; ls -ld /etc/passwd 2>&1' 2>&1)
echo "  > $out"
echo "$out" | grep -qE "^OK uid=1000 gid=1000( groups=1000)? USER=tester HOME=/home/u SHELL=/bin/sh PWD=/home/u" \
	&& ok "3.4/A: -H \$6\$ login as uid 1000 w/o passwd entry, env synthesized" || bad "A login: $out"
sshpw $A 'Hash pw 35' tester true 2>/dev/null && bad "A: wrong password accepted" || ok "3.4/A: wrong password rejected"
sshpw $A 'Hash pw 34' root true 2>/dev/null && bad "A: wrong user accepted" || ok "3.4/A: wrong user rejected"
sshpw $A 'Hash pw 34' tester 'exit 9'; rc=$?
[ $rc = 9 ] && ok "3.4/A: exec exit status propagated (9)" || bad "A exit status $rc"
# pty
out=$(printf '%s\n' 'Hash pw 34' > "$T/apw"; (printf 'echo P$((7*6))P; tty; ls -l $(tty); exit 4\n'; sleep 8) | ASKPASS_FILE="$T/apw" SSH_ASKPASS="$T/askpass" \
	SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHO[@]}" -p $A -tt -o PubkeyAuthentication=no tester@127.0.0.1 2>&1); rc=$?
o2=$(echo "$out" | tr -d '\r')
echo "$o2" | grep -E "^P42P|^/dev/pts|^crw" | sed 's/^/  > /'
echo "$o2" | grep -qx "P42P" && echo "$o2" | grep -q "^/dev/pts/[0-9]" && [ $rc = 4 ] \
	&& ok "3.4/A: interactive pty shell (devpts, exit 4): $(echo "$o2" | grep -m1 '^crw' | awk '{print $1, $3, $4}')" || bad "A pty rc=$rc: $out"
# host key persistence: kill the listener via its -x pid file; the guest loop restarts it
fp1=$(ssh-keygen -lf "$KH" | awk '{print $2}' | sort -u)
sshpw $A 'Hash pw 34' tester 'cat /home/u/a.pid; kill $(cat /home/u/a.pid)' >/dev/null 2>&1
sleep 6
grep -aq "M34: server A exited" "$T/serial.log" && ok "3.4/A: -x pid file written; listener killed and restarted" || bad "A restart"
printf '%s\n' 'Hash pw 34' > "$T/apw"
ASKPASS_FILE="$T/apw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh -F /dev/null \
	-o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -o LogLevel=ERROR -o ConnectTimeout=60 -p $A \
	-o PubkeyAuthentication=no tester@127.0.0.1 true </dev/null 2>"$T/err" \
	&& ok "3.4/A: host key persisted across server restart (StrictHostKeyChecking=yes, $fp1)" || bad "A persistence: $(cat "$T/err")"
# --- B: -P @file + -k
sshpw $B 'File pw 34' tester true && ok "3.4/B: -P @file password login" || bad "B -P @file"
sshpw $B 'File pw 3' tester true 2>/dev/null && bad "B: prefix accepted" || ok "3.4/B: wrong (prefix) password rejected"
sshkey $B "$T/id1" tester true && ok "3.4/B: -k inline ed25519 key login" || bad "B -k"
sshkey $B "$T/id3" tester true 2>/dev/null && bad "B: other key accepted" || ok "3.4/B: unlisted key rejected"
# -L forwarding to the guest's busybox httpd on 127.0.0.1:8080
rh=$(sshkey $B "$T/id1" tester 'sha256sum /www/blob' | cut -c1-64)
ssh "${SSHO[@]}" -p $B -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -N -L $((HP+9)):127.0.0.1:8080 tester@127.0.0.1 </dev/null >/dev/null 2>&1 &
F=$!; sleep 5
lh=$(curl -s -m 60 http://127.0.0.1:$((HP+9))/blob | sha256sum | cut -c1-64)
kill $F 2>/dev/null; wait $F 2>/dev/null
[ -n "$rh" ] && [ "$lh" = "$rh" ] && ok "3.4/B: -L forward to guest httpd, 1 MiB sha256 matches" || bad "B -L ($lh vs $rh)"
# scp -O (builtin applet, no scp on the guest)
head -c 300000 /dev/urandom > "$T/up"
SC=(-O -F /dev/null -o UserKnownHostsFile="$KH" -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -P $B)
scp "${SC[@]}" "$T/up" tester@127.0.0.1:up.bin && scp "${SC[@]}" tester@127.0.0.1:up.bin "$T/down" && cmp -s "$T/up" "$T/down" \
	&& ok "3.4/B: scp -O upload+download (builtin scp; guest has no scp binary)" || bad "B scp"
# --- C: -K file
sshkey $C "$T/id2" tester true && ok "3.4/C: -K authorized_keys file login" || bad "C -K"
sshkey $C "$T/id1" tester true 2>/dev/null && bad "C: unlisted key accepted" || ok "3.4/C: key not in -K file rejected"
sshpw $C x tester true 2>/dev/null && bad "C: password accepted w/o -P/-H" || ok "3.4/C: no -P/-H -> password auth refused"
# --- D: literal -P, daemon mode; argv must not show the password
out=$(sshpw $D 'Literal Secret 34' tester 'for p in $(pidof dropbearmulti); do tr "\0" " " < /proc/$p/cmdline; echo; tr "\0" "\n" < /proc/$p/environ | grep -c Secret; done; env | grep -c DROPBEAR_PASSWORD' 2>&1)
echo "$out" | grep -q "Literal\|Secret 34" && bad "3.4/D: password visible in /proc/*/cmdline or environ: $out" \
	|| { echo "$out" | grep -q -- "-p 2225" && ok "3.4/D: daemon mode (no -F) login; -P literal and DROPBEAR_PASSWORD wiped from /proc/<pid>/cmdline+environ, not in session env: $(echo "$out" | grep -m1 -- '-p 2225' | sed 's/  */ /g')"; } \
	|| bad "D: $out"
# --- privilege handling (review round)
l=$(grep -a "^M34: setuid-root" "$T/serial.log")
echo "$l" | grep -q "rc=1 .*Refusing to run setuid" && ok "3.4: setuid-root copy refuses to run for uid 1000 ($(echo "$l" | sed 's/.*msg=//'))" || bad "setuid: $l"
l=$(grep -a "^M34: setgid-root" "$T/serial.log")
echo "$l" | grep -q "rc=1 .*Refusing to run setuid" && ok "3.4: setgid-root copy refuses to run for uid 1000" || bad "setgid: $l"
l=$(grep -a "^M34: root -U alice" "$T/serial.log")
echo "$l" | grep -q "rc=1 .*would give it a root shell" && ok "3.4: root + -U <real account uid 1000> refuses to start" || bad "root -U alice: $l"
out=$(sshpw $E 'Hash pw 34' admin 'echo "ID=$(id -u)"; ls /home/u/ekey /home/u/e.pid 2>&1; ls /ekey /e.pid 2>&1; for p in $(pidof dropbearmulti); do tr "\0" " " < /proc/$p/cmdline; echo; done' 2>&1)
echo "$out" | sed 's/^/  > /'
echo "$out" | grep -qx "ID=0" && ok "3.4/E: started as root, synthetic -U admin -> root session (same uid as server, no switch)" || bad "E login: $out"
echo "$out" | grep -qx "/home/u/ekey" && echo "$out" | grep -qx "/home/u/e.pid" && echo "$out" | grep -q "/ekey: No such file" \
	&& ok "3.4/E: daemon mode with relative -r ekey / -x e.pid: created in the start directory, not in /" || bad "E relative paths: $out"
echo "$out" | grep -q -- "-p 2226" && ! echo "$out" | grep -q 'K34salt' \
	&& ok "3.4/E: -H literal wiped from /proc/<pid>/cmdline" || bad "E -H wipe: $out"
sshpw $E 'Hash pw 34' tester true 2>/dev/null && bad "E: wrong user accepted" || ok "3.4/E: root server still only accepts -U admin"
grep -aq "Login 'admin' runs as uid 0 .*(ROOT)" "$T/serial.log" && ok "3.4/E: startup log names the effective uid (ROOT)" || bad "E: no ROOT startup log line"
# --- F/G: -R with the key absent at startup, long -r paths (use-after-free regression)
LONGD=$(printf 'long-directory-name-%02d/' 1 2 3 4 5 6 7 8)
for sv in "F $((HP+7)) conc-first /tmp/x/rep/ssh_host_ed25519 fcwd" \
	"G $((HP+8)) seq-first /tmp/x/rep2/${LONGD}ssh_host_ed25519_key gcwd"; do
	read -r name port order kp cwd <<<"$sv"
	rep_conns "$order" "$port" tester "$T/id1" "$T/rep$name"
	read -r n nd ne fp <<<"$(rep_summary "$T/rep$name")"
	g=$(sshkey "$port" "$T/id1" tester "echo KFP \$(/data/dropbearmulti dropbearkey -y -f '$kp' | grep '^ssh-ed25519 ')
		echo CWD \$(ls -A /home/u/$cwd | tr '\n' ' ')
		echo KDIR \$(ls -A \$(dirname '$kp') | tr '\n' ' ')
		echo MODE \$(stat -c %a '$kp' 2>/dev/null || ls -l '$kp' | cut -c1-10)" 2>&1)
	kfp=$(echo "$g" | sed -n 's/^KFP //p' | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
	[ "$n" = 12 ] && [ "$nd" = 1 ] && [ "$ne" = 0 ] && [ -n "$kfp" ] && [ "$fp" = "$kfp" ] \
		&& ok "3.4/$name: -R key absent at start, -r ${#kp}-char path: 12 connections ($order), one key = the file's ($fp)" \
		|| bad "3.4/$name: connections=$n distinct=$nd errors=$ne first=$fp keyfile=$kfp: $(sort "$T/rep$name/fps" | uniq -c | tr '\n' ' ' | cut -c1-300)"
	echo "$g" | grep -qx "CWD" && echo "$g" | grep -qx "KDIR $(basename "$kp")" && echo "$g" | grep -qE "^MODE (600|-rw-------)$" \
		&& ok "3.4/$name: server cwd empty, key dir holds only the 0600 key" || bad "3.4/$name: $(echo "$g" | grep -v KFP | tr '\n' '|')"
done
gl=$(grep -a "Generated hostkey" "$T/serial.log")
! grep -aqE "Failed moving key file|Couldn't read or generate hostkey" "$T/serial.log" \
	&& [ "$(echo "$gl" | grep -c "Generated hostkey /tmp/x/rep/ssh_host_ed25519, fingerprint")" -ge 1 ] \
	&& [ "$(echo "$gl" | grep -c "Generated hostkey /tmp/x/rep2/${LONGD}ssh_host_ed25519_key, fingerprint")" -ge 1 ] \
	&& [ "$(echo "$gl" | grep -v "Generated hostkey /home/u/hostkey, \|Generated hostkey /home/u/ekey, " | grep -vc "Generated hostkey /tmp/x/rep")" = 0 ] \
	&& ok "3.4/F+G: server log names only the -r paths ($(echo "$gl" | grep -c /tmp/x/rep)x Generated), no key failures" \
	|| bad "3.4/F+G log: $(grep -aE "Generated hostkey|Failed moving|Couldn't read or generate" "$T/serial.log" | sed 's/^\[[0-9]*\] [^ ]* [^ ]* //' | sort | uniq -c | head -6 | tr '\n' '|')"
# --- algorithms negotiated
alg=$(ssh -v "${SSHO[@]}" -p $C -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id2" tester@127.0.0.1 true </dev/null 2>&1 | grep -E "kex: algorithm|kex: host key|server->client cipher" | sed 's/debug1: //' | tr '\n' ';')
echo "$alg" | grep -q "curve25519-sha256" && echo "$alg" | grep -q "ssh-ed25519" && echo "$alg" | grep -q chacha20-poly1305 \
	&& ok "3.4: negotiated $alg" || bad "algorithms: $alg"
# the negative checks above must have been real rejections, not connection failures
grep -aq "Bad password attempt for 'tester'" "$T/serial.log" && grep -aq "Login attempt for nonexistent user" "$T/serial.log" \
	&& ok "3.4: rejections confirmed in server log (bad password + nonexistent user lines)" || bad "rejections not seen in server log"
echo "== guest serial (dropbear lines, tail):"; grep -aE "^\[[0-9]+\] " "$T/serial.log" | tail -8 | sed 's/^/  /'
l=$(grep -aiE "Illegal instruction|SIGILL|Bad system call|unhandled|Unable to handle|Oops|segfault" "$T/serial.log" | head -1)
[ -n "$l" ] && bad "kernel/console reports: $l" || ok "no SIGILL/SIGSYS/oops/segfault on the 3.4 console"
echo "== RESULT: $PASS passed, $FAIL failed"
printf '%s\n' "${RES[@]}" > "${MATRIX_OUT:-/dev/null}"
[ $FAIL -eq 0 ]
