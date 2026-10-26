#!/bin/sh
# Boot the Linux 3.4.113 ARMv7 test VM (qemu vexpress-a15, TCG).
#
#   ./run-qemu.sh [extra.cpio.gz ...]
#
# Env knobs:
#   VARIANT=nopasswd|passwd  base initramfs (default nopasswd: no /etc/passwd at all)
#   CPU=cortex-a7|cortex-a15 (default: cortex-a7 if this qemu accepts it on vexpress-a15,
#                            else cortex-a15 -- QEMU >= 10 rejects a7 there;
#                            never cortex-a9: no VFPv4 -> SIGILL)
#   PORT=2222                host port forwarded to guest tcp/22 (bound on 127.0.0.1)
#   SMP=2 MEM=256
#   APPEND="net=dhcp testexit=poweroff"   extra kernel cmdline words
#   QEMU=qemu-system-arm
# Exit qemu: Ctrl-A x  (monitor: Ctrl-A c)
set -eu
D=$(cd "$(dirname "$0")" && pwd)
VARIANT=${VARIANT:-nopasswd}; CPU=${CPU:-}; PORT=${PORT:-2222}
SMP=${SMP:-2}; MEM=${MEM:-256}; APPEND=${APPEND:-}; QEMU=${QEMU:-qemu-system-arm}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
cat "$D/initramfs-$VARIANT.cpio.gz" "$@" > "$T/initrd.cpio.gz"

# -audio none only exists on qemu >= 7.1; older qemu: silence ALSA via env
AUDIO="-audio none"
"$QEMU" -help 2>/dev/null | grep -q '^-audio ' || { AUDIO=""; export QEMU_AUDIO_DRV=none; }

# an accepted CPU gets as far as loading the (nonexistent) kernel
if [ -z "$CPU" ]; then
  CPU=cortex-a15
  "$QEMU" -M vexpress-a15 -cpu cortex-a7 -nodefaults -display none -monitor none -serial none $AUDIO \
    -kernel /nonexistent-cpu-probe </dev/null 2>&1 | grep -q "could not load kernel" && CPU=cortex-a7
fi
echo "run-qemu: -cpu $CPU" >&2

# not exec: the trap must still remove $T afterwards
"$QEMU" -M vexpress-a15 -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -kernel "$D/zImage" -dtb "$D/vexpress-v2p-ca15-tc1.dtb" -initrd "$T/initrd.cpio.gz" \
  -append "console=ttyAMA0 rdinit=/init $APPEND" \
  -nic "user,hostfwd=tcp:127.0.0.1:$PORT-:22" $AUDIO -nographic
