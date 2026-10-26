#!/bin/bash
# Build the two base initramfs variants with the kernel's own gen_init_cpio
# (rootless: device nodes are described in the list, no mknod needed).
#   usage: mkrootfs.sh <busybox> <gen_init_cpio> <scriptdir> <outdir>
set -euo pipefail
BB=$1; GIC=$2; SD=$3; OUT=$4
mkdir -p "$OUT"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

cat > "$T/default.script" <<'EOF'
#!/bin/sh
case "$1" in
  deconfig) ip addr flush dev "$interface"; ip link set "$interface" up ;;
  bound|renew)
    ip addr flush dev "$interface"
    ip addr add "$ip/${mask:-24}" dev "$interface"
    for r in $router; do ip route add default via "$r" dev "$interface"; break; done
    : > /etc/resolv.conf
    for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done ;;
esac
exit 0
EOF
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$T/passwd"
printf 'root:x:0:\ntty:x:5:\n' > "$T/group"

base_list() {
cat <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
dir /root 0700 0 0
dir /bin 0755 0 0
dir /sbin 0755 0 0
dir /usr 0755 0 0
dir /usr/bin 0755 0 0
dir /usr/sbin 0755 0 0
dir /usr/share 0755 0 0
dir /usr/share/udhcpc 0755 0 0
dir /var 0755 0 0
dir /var/run 0755 0 0
dir /var/log 0755 0 0
dir /etc 0755 0 0
dir /data 0755 0 0
file /bin/busybox $BB 0755 0 0
file /init $SD/init 0755 0 0
file /usr/share/udhcpc/default.script $T/default.script 0755 0 0
EOF
}

base_list > "$T/list-nopasswd"
{ base_list
  echo "file /etc/passwd $T/passwd 0644 0 0"
  echo "file /etc/group $T/group 0644 0 0"; } > "$T/list-passwd"

for v in nopasswd passwd; do
  "$GIC" "$T/list-$v" | gzip -9n > "$OUT/initramfs-$v.cpio.gz"
done
ls -la "$OUT"/initramfs-*.cpio.gz
