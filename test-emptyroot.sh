#!/usr/bin/env bash
# "Empty rootfs" test: run the server in a rootless podman container whose
# image holds ONLY the binary, a static /bin/sh and /dev (podman adds /proc,
# /sys and /etc/hostname). No /etc/passwd, /etc/shadow, /etc/group, no shared
# libraries, no config files; the container uid 4321 has no passwd entry.
#
# x86_64 host without binfmt_misc: the image also carries qemu-arm-static and
# the shell is a static x86 busybox (on the real board it is the board's sh).
#
# Usage: QEMU=... BUSYBOX=/path/static/x86/busybox ./test-emptyroot.sh [binary]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(readlink -f "${1:-$HERE/out/dropbearmulti}")"
QEMU="${QEMU:-qemu-arm-static}"; BUSYBOX="${BUSYBOX:-busybox}"
PORT=${PORT:-22044}
T="$(mktemp -d /tmp/dbroot.XXXXXX)"
IMG=localhost/dbtest-emptyroot:tmp
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
trap 'podman rm -f dbtest-er >/dev/null 2>&1; podman rmi -f $IMG >/dev/null 2>&1; rm -rf "$T"' EXIT

R="$T/rootfs"; mkdir -p "$R/bin" "$R/data"; chmod 1777 "$R/data"
cp "$BIN" "$R/dropbearmulti"; cp "$QEMU" "$R/qemu-arm-static"
cp "$BUSYBOX" "$R/bin/busybox"; ln -s busybox "$R/bin/sh"
# login shell for the test: routes the server's builtin-scp re-exec via qemu
cat > "$R/bin/loginsh" <<'EOF'
#!/bin/sh
if [ "$1" = "-c" ]; then
	cmd=$(printf '%s' "$2" | /bin/busybox sed "s#^exec '/dropbearmulti' --applet#exec /qemu-arm-static /dropbearmulti --applet#")
	exec /bin/sh -c "$cmd"
fi
exec /bin/sh "$@"
EOF
chmod 755 "$R/bin/loginsh"
tar -C "$R" -cf "$T/rootfs.tar" .
podman import -q "$T/rootfs.tar" $IMG >/dev/null

ssh-keygen -q -t ed25519 -N '' -C erkey -f "$T/id"
echo "== image contents:"; tar -tvf "$T/rootfs.tar" | awk '{print "  "$1, $3, $6, $7, $8}'

podman run -d --name dbtest-er --network=host --no-hosts --dns=none --user 4321:4321 $IMG \
	/qemu-arm-static /dropbearmulti dropbear -F -E -p "127.0.0.1:$PORT" -r /data/hostkey -R \
	-P 'pw 123' -k "$(cat "$T/id.pub")" -s /bin/loginsh >/dev/null
sleep 3
SSHO=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$PORT")
out=$(ssh "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id" root@127.0.0.1 \
	'echo "id=$(id -u):$(id -g) USER=$USER HOME=$HOME SHELL=$SHELL PWD=$(pwd)"; ls /etc; ls /lib 2>&1' </dev/null 2>&1)
echo "$out" | sed 's/^/  > /'
echo "$out" | grep -q "id=4321:4321 USER=root HOME=/ SHELL=/bin/loginsh PWD=/" \
	&& ok "key login in empty rootfs, default user 'root', synthesized home/shell" || bad "empty rootfs key login"
cat > "$T/askpass" <<EOF
#!/bin/sh
echo 'pw 123'
EOF
chmod 755 "$T/askpass"
SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHO[@]}" \
	-o PubkeyAuthentication=no root@127.0.0.1 true </dev/null && ok "password login in empty rootfs" || bad "password login"
head -c 100000 /dev/urandom > "$T/blob"
scp -O "${SSHO[@]/-p/-P}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id" "$T/blob" root@127.0.0.1:/data/blob \
	&& scp -O "${SSHO[@]/-p/-P}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id" root@127.0.0.1:/data/blob "$T/blob2" \
	&& cmp -s "$T/blob" "$T/blob2" && ok "scp -O up+down in empty rootfs (builtin scp applet)" || bad "scp in empty rootfs"
echo "== server log:"; podman logs dbtest-er 2>&1 | tail -6 | sed 's/^/  /'
echo "== RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
