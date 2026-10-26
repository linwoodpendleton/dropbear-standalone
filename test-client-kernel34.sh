#!/usr/bin/env bash
# dbclient on a REAL Linux 3.4.113 kernel: qemu-system-arm vexpress-a15,
# -cpu cortex-a7 (cortex-a15 on QEMU >= 10) (TCG), base initramfs WITHOUT /etc/passwd (qemu34/). The
# guest runs test-client-kernel34-guest.sh: the client (uid 1000, no passwd
# entry) talks to the host's OpenSSH sshd (started unprivileged on the host,
# reached as 10.0.2.2 through qemu user-net) and to its own dropbear server.
#
# Usage: QEMU=/path/qemu-arm-static ./test-client-kernel34.sh [client-binary]
#   (qemu-arm-static only runs dropbearkey on the host to make a test key;
#    qemu-system-arm from PATH, else the localhost/qemu-arm podman image)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-ossh-harness.sh"
CBIN="$(readlink -f "${1:-$HERE/out/variants/dropbearmulti-client}")"
QEMU="${QEMU:-qemu-arm-static}"
Q34="$HERE/qemu34"
BASE=${BASE:-23500}
PO=$((BASE+1)); PH=$((BASE+2)); PR=$((BASE+3))
T="$(mktemp -d /tmp/dbc34.XXXXXX)"; chmod 755 "$T"
PASS=0; FAIL=0

mkdir -p "$T/data" "$T/www"
cp "$CBIN" "$T/data/client"
"$QEMU" "$CBIN" dropbearkey -t ed25519 -f "$T/data/kdb" >/dev/null 2>&1
"$QEMU" "$CBIN" dropbearkey -y -f "$T/data/kdb" | grep '^ssh-ed25519' > "$T/kdb.pub"
ssh-keygen -q -t ed25519 -N '' -C k34-ossh -f "$T/data/kossh"
ssh-keygen -q -t ed25519 -N 'pass phrase' -C k34-enc -f "$T/data/kenc"
cat "$T/kdb.pub" "$T/data/kossh.pub" > "$T/ak"
head -c 1048576 /dev/urandom > "$T/www/blob"
OPW='Open pw 34!'
cat > "$T/data/vars" <<EOF
PO=$PO; PH=$PH; PR=$PR; OPW='$OPW'; HOSTARCH=$(uname -m)
HOSTSUM=$(sha256sum < "$T/www/blob" | cut -d' ' -f1)
EOF
cp "$HERE/test-client-kernel34-guest.sh" "$T/data/test.sh"
chmod 0755 "$T/data" "$T/data/client" "$T/data/test.sh"; chmod 0644 "$T/data"/{kdb,kossh,kossh.pub,kenc,vars}
( cd "$T" && find data | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) | gzip -9n > "$T/data.cpio.gz"
cat "$Q34/initramfs-nopasswd.cpio.gz" "$T/data.cpio.gz" > "$T/initrd.cpio.gz"

start_ossh "$T/ossh" "$PO" "$OPW" "$T/ak" || { echo "cannot start OpenSSH sshd"; exit 1; }
python3 -m http.server --bind 127.0.0.1 --directory "$T/www" "$PH" >/dev/null 2>&1 &
HTTPD=$!

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
	-initrd "$T/initrd.cpio.gz" -append "console=ttyAMA0 rdinit=/init" -nic user -audio none
	-display none -monitor none -serial "file:$T/serial.log")
if command -v qemu-system-arm >/dev/null; then
	qemu-system-arm "${QARGS[@]}" </dev/null >/dev/null 2>"$T/qemu.err" &
	VM=$!; VMKILL="kill $VM"
else
	podman run -d --name dbc34-$$ --network=host --userns=keep-id -v "$T:$T:Z" -v "$Q34:$Q34:ro,Z" \
		localhost/qemu-arm:24.04 qemu-system-arm "${QARGS[@]}" >/dev/null || { echo "cannot start VM"; exit 1; }
	VMKILL="podman rm -f dbc34-$$"
fi
trap '$VMKILL >/dev/null 2>&1; stop_ossh "$T/ossh"; kill $HTTPD 2>/dev/null; cp "$T/serial.log" "${SERIAL_KEEP:-/dev/null}" 2>/dev/null; sleep 0.5; $NSRUN rm -rf "$T" 2>/dev/null || rm -rf "$T"' EXIT
for _ in $(seq 1800); do grep -aq "M34C-DONE" "$T/serial.log" 2>/dev/null && break; sleep 1; done
grep -aq "M34C-DONE" "$T/serial.log" || { echo "guest did not finish"; tail -40 "$T/serial.log"; exit 1; }

grep -aE "^M34C( |:)" "$T/serial.log" | sed 's/^M34C PASS: /PASS: 3.4: /; s/^M34C FAIL: /FAIL: 3.4: /; s/^M34C: /  /'
PASS=$(grep -ac "^M34C PASS: " "$T/serial.log"); FAIL=$(grep -ac "^M34C FAIL: " "$T/serial.log")
$NSRUN grep -q "Accepted password for pwuser" "$T/ossh/sshd.log" && grep -aq "M34C PASS: host OpenSSH: host key prompt" "$T/serial.log" \
	&& { echo "PASS: host sshd log confirms the guest's password login"; PASS=$((PASS+1)); } || { echo "FAIL: no password login in sshd log"; FAIL=$((FAIL+1)); }
l=$(grep -aiE "Illegal instruction|SIGILL|Bad system call|unhandled|Unable to handle|Oops|segfault" "$T/serial.log" | head -1)
[ -n "$l" ] && { echo "FAIL: console reports: $l"; FAIL=$((FAIL+1)); } || { echo "PASS: no SIGILL/SIGSYS/oops/segfault on the 3.4 console"; PASS=$((PASS+1)); }
echo "== RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
