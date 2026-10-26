#!/bin/bash
# Smoke test, runs INSIDE localhost/qemu-arm:24.04 with /w = qemu34 artifact dir.
#   usage: smoke-test.sh <variant: nopasswd|passwd> [cpu: cortex-a7|cortex-a15]
#   (QEMU >= 10 rejects cortex-a7 on vexpress-a15: pass cortex-a15 there)
set -uo pipefail
V=${1:-nopasswd}; CPU=${2:-cortex-a7}
cd /w
T=$(mktemp -d)
cat > "$T/test.sh" <<'EOF'
#!/bin/sh
echo "SMOKE: uname -r = $(uname -r)"
echo "SMOKE: uname -a = $(uname -a)"
grep -E '^(Processor|model name|Features|CPU part|CPU architecture)' /proc/cpuinfo | sort -u | sed 's/^/SMOKE: /'
echo "SMOKE: id = $(id 2>&1)"
echo "SMOKE: ptmx: $(ls -l /dev/ptmx)  pts: $(mount | grep devpts)"
( while true; do echo "NK34-NC-OK $(uname -r)" | nc -l -p 22; done ) >/dev/null 2>&1 &
echo "SMOKE-READY"
EOF
bash scripts/mkdata-cpio.sh "$T/data.cpio.gz" "$T/test.sh" >/dev/null
cat "initramfs-$V.cpio.gz" "$T/data.cpio.gz" > "$T/initrd.cpio.gz"

LOG=/w/smoke-$V-$CPU.log
: > "$LOG"
QEMU=(qemu-system-arm -M vexpress-a15 -cpu "$CPU" -smp 2 -m 256
  -kernel zImage -dtb vexpress-v2p-ca15-tc1.dtb -initrd "$T/initrd.cpio.gz"
  -append "console=ttyAMA0 rdinit=/init"
  -nic user,hostfwd=tcp::2222-:22
  -audio none -display none -monitor none -serial "file:$LOG")
echo "QEMU: ${QEMU[*]}"
t0=$(date +%s.%N)
"${QEMU[@]}" & QPID=$!
ok=0
for i in $(seq 1 600); do
  if grep -q SMOKE-READY "$LOG"; then ok=1; break; fi
  kill -0 $QPID 2>/dev/null || break
  sleep 0.1
done
t1=$(date +%s.%N)
echo "BOOT-TO-SMOKE-READY: $(awk "BEGIN{printf \"%.2f\", $t1 - $t0}") s (ok=$ok)"
sleep 1
R=$(timeout 5 nc -w 3 127.0.0.1 2222 </dev/null)
echo "HOSTFWD 127.0.0.1:2222 -> guest:22 replied: [$R]"
kill $QPID; wait $QPID 2>/dev/null
echo "----- serial log -----"
cat "$LOG"
rm -rf "$T"
[ "$ok" = 1 ] && [[ "$R" == NK34-NC-OK* ]] && echo "SMOKE PASS" || { echo "SMOKE FAIL"; exit 1; }
