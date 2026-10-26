#!/usr/bin/env bash
# Functional test of out/dropbearmulti under qemu-arm (user mode) on an
# x86_64 Linux host, driven by the stock OpenSSH client.
#
# Without binfmt_misc the kernel cannot exec ARM programs, so the login shell
# used here is a host /bin/sh, and the builtin-scp re-exec is routed through
# qemu by a small wrapper shell (that wrapper also logs the command the server
# asked the shell to run, which is what we want to check).
#
# Usage: QEMU=/path/qemu-arm-static ./test-qemu.sh [binary]
#   (QEMU=env on an ARM host, or for a host-native ASan build from build.sh --asan)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(readlink -f "${1:-$HERE/out/dropbearmulti}")"
QEMU="${QEMU:-qemu-arm-static}"
T="$(mktemp -d /tmp/dbtest.XXXXXX)"
PORT=${PORT:-22022}
PASS=0; FAIL=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
run()  { "$QEMU" "$BIN" "$@"; }

mkdir -p "$T/home/.ssh" "$T/files"
chmod 755 "$T/home"
cat > "$T/askpass" <<'EOF'
#!/bin/sh
cat "$ASKPASS_FILE"
EOF
chmod 755 "$T/askpass"
# login shell: logs the -c command, routes "exec '<self>' --applet ..." via qemu
cat > "$T/shell" <<EOF
#!/bin/sh
if [ "\$1" = "-c" ]; then
	printf '%s\n' "\$2" >> "$T/shell.log"
	cmd=\$(printf '%s' "\$2" | sed "s#^exec '$BIN' --applet#exec $QEMU '$BIN' --applet#")
	exec /bin/sh -c "\$cmd"
fi
exec /bin/sh "\$@"
EOF
chmod 755 "$T/shell"
ssh-keygen -q -t ed25519 -N '' -C testkey -f "$T/id1"
ssh-keygen -q -t ed25519 -N '' -C otherkey -f "$T/id2"

SSHO=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=20 -p "$PORT")
sshpw() { # password user cmd...
	local pw="$1" u="$2"; shift 2
	printf '%s\n' "$pw" > "$T/pw"
	ASKPASS_FILE="$T/pw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
		setsid -w ssh "${SSHO[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password \
		-o NumberOfPasswordPrompts=1 "$u@127.0.0.1" "$@" </dev/null
}
sshkey() { # keyfile user cmd...
	local k="$1" u="$2"; shift 2
	ssh "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$k" "$u@127.0.0.1" "$@" </dev/null
}
SRV=""
start() { # args...
	stop
	"$QEMU" "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" -r "$T/hostkey" -R \
		-s "$T/shell" -D "$T/home" "$@" 2>>"$T/server.log" &
	SRV=$!
	for _ in $(seq 50); do
		(exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && return 0
		sleep 0.2
	done
	echo "server did not start"; cat "$T/server.log"; return 1
}
# (TERM is resent: qemu-user 6.2 can lose a signal that arrives just as the
# guest enters select(), and the listener would then never exit)
stop() {
	[ -n "$SRV" ] || return 0
	local i
	for i in $(seq 50); do
		case "$(ps -o stat= -p "$SRV" 2>/dev/null)" in ""|Z*) break;; esac
		kill "$SRV" 2>/dev/null; sleep 0.2
	done
	kill -9 "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
}
trap 'stop; rm -rf "$T"' EXIT

echo "== binary: $BIN"
run 2>&1 | head -3
run dropbear -V 2>&1 | head -1

# --- dropbearkey
run dropbearkey -t ed25519 -f "$T/k1" >/dev/null 2>&1 && run dropbearkey -y -f "$T/k1" | grep -q '^ssh-ed25519 ' \
	&& ok "dropbearkey ed25519 generate + -y" || bad "dropbearkey"
run dropbearkey -t rsa -f "$T/k2" >/dev/null 2>&1 && bad "dropbearkey rsa should be compiled out" || ok "dropbearkey rejects rsa (compiled out)"

# --- -P plaintext password
start -U tester -P 's3cret pass' || exit 1
out=$(sshpw 's3cret pass' tester 'echo HELLO; id -u; echo "HOME=$HOME SHELL=$SHELL USER=$USER"; pwd' 2>&1)
# -R creates the key on first connection, in the -r file
[ -s "$T/hostkey" ] && ok "-R generated host key into -r file" || bad "-R host key"
echo "$out" | grep -q HELLO && ok "password login (-P)" || bad "password login (-P): $out"
echo "$out" | grep -q "HOME=$T/home SHELL=$T/shell USER=tester" && ok "env HOME/SHELL/USER synthesized" || bad "env: $out"
echo "$out" | grep -qx "$(id -u)" && ok "session runs as server uid" || bad "uid: $out"
t0=$(date +%s%N)
sshpw 'wrong' tester true >/dev/null 2>&1 && bad "wrong password accepted" || ok "wrong password rejected"
t1=$(date +%s%N); dt=$(( (t1-t0)/1000000 ))
[ $dt -ge 250 ] && ok "failed-auth delay ${dt}ms (>=250ms)" || bad "failed-auth delay only ${dt}ms"
sshpw 's3cret pass' root true >/dev/null 2>&1 && bad "other user accepted" || ok "other user name rejected"
sshpw 's3cret pas' tester true >/dev/null 2>&1 && bad "prefix password accepted" || ok "prefix of password rejected"
sshpw 's3cret passX' tester true >/dev/null 2>&1 && bad "longer password accepted" || ok "longer password rejected"
sshkey "$T/id1" tester true 2>/dev/null && bad "pubkey accepted with no keys configured" || ok "no key configured -> pubkey rejected"
# pty
# (stdin must stay open: a channel EOF closes the pty master right away)
out=$(printf '%s\n' 's3cret pass' > "$T/pw"; (sleep 5) | ASKPASS_FILE="$T/pw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
	setsid -w ssh "${SSHO[@]}" -tt -o PubkeyAuthentication=no tester@127.0.0.1 'tty; ls -l $(tty)' 2>&1)
echo "$out" | grep -q '^/dev/pts/' && ok "pty allocated: $(echo "$out" | grep -m1 '^c' | tr -d '\r')" || bad "pty: $out"
stop

# --- -P @file and DROPBEAR_PASSWORD
printf 'filepw\n' > "$T/pwfile"
start -U tester -P "@$T/pwfile" || exit 1
sshpw filepw tester true && ok "-P @file" || bad "-P @file"
stop
DROPBEAR_PASSWORD=envpw start -U tester || exit 1
sshpw envpw tester true && ok "DROPBEAR_PASSWORD env" || bad "DROPBEAR_PASSWORD env"
out=$(sshpw envpw tester 'env' 2>&1)
echo "$out" | grep -q DROPBEAR_PASSWORD && bad "DROPBEAR_PASSWORD leaked into session" || ok "DROPBEAR_PASSWORD not passed to session"
stop

# --- -H crypt hashes
H6=$(openssl passwd -6 -salt 'saltsalt12345678' 'hashpw6')
H5=$(openssl passwd -5 -salt 'saltysalt' 'hashpw5')
start -U tester -H "$H6" || exit 1
sshpw hashpw6 tester true && ok "-H \$6\$ sha512-crypt" || bad "-H \$6\$"
sshpw hashpw5 tester true 2>/dev/null && bad "-H \$6\$ wrong pw accepted" || ok "-H \$6\$ wrong pw rejected"
stop
start -U tester -H "$H5" || exit 1
sshpw hashpw5 tester true && ok "-H \$5\$ sha256-crypt" || bad "-H \$5\$"
stop
# crypt("rounds pw", "$6$rounds=2500$abcdefgh") from glibc/libxcrypt (openssl passwd
# has no rounds option; Python >= 3.13 has no crypt module)
HR='$6$rounds=2500$abcdefgh$exwL/vMjQLh6DLpSlO0aBOPwKDBZQoAoISTuQk8AQEs4ngLymcY/F21YySMGYTMTmGxG7AL.cUQmDgK4lxI5z.'
echo "$HR" > "$T/hashfile"
start -U tester -H "@$T/hashfile" || exit 1
sshpw 'rounds pw' tester true && ok "-H @file with \$6\$rounds=2500\$" || bad "-H rounds=2500"
stop
H1=$(openssl passwd -1 -salt abc 'md5pw')
"$QEMU" "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" -r "$T/hostkey" -U tester -H "$H1" 2>&1 | grep -q "Unsupported -H" \
	&& ok "-H \$1\$ (md5) refused at startup" || bad "-H \$1\$ not refused"
"$QEMU" "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" -r "$T/hostkey" -U tester -P x -H "$H6" 2>&1 | grep -q "can't be used together" \
	&& ok "-P with -H refused" || bad "-P with -H not refused"

# --- public keys
start -U tester -k "$(cat "$T/id1.pub")" || exit 1
sshkey "$T/id1" tester true && ok "-k inline key" || bad "-k inline key"
sshkey "$T/id2" tester true 2>/dev/null && bad "-k: other key accepted" || ok "-k: other key rejected"
sshpw x tester true 2>/dev/null && bad "password accepted without -P/-H" || ok "no -P/-H -> password auth refused"
stop
cp "$T/id2.pub" "$T/keys"; chmod 600 "$T/keys"
start -U tester -K "$T/keys" || exit 1
sshkey "$T/id2" tester true && ok "-K authorized_keys file" || bad "-K file"
sshkey "$T/id1" tester true 2>/dev/null && bad "-K: unlisted key accepted" || ok "-K: unlisted key rejected"
chmod 666 "$T/keys"
sshkey "$T/id2" tester true 2>/dev/null && bad "-K world-writable file accepted" || ok "-K world-writable file refused"
chmod 600 "$T/keys"
stop
echo "command=\"/bin/false\" $(cat "$T/id1.pub")" > "$T/keys2"; chmod 600 "$T/keys2"
start -U tester -K "$T/keys2" || exit 1
sshkey "$T/id1" tester true 2>/dev/null && bad "key with options accepted (should fail closed)" || ok "key line with options refused (fail closed)"
stop
cp "$T/id1.pub" "$T/home/.ssh/authorized_keys"; chmod 700 "$T/home/.ssh"; chmod 600 "$T/home/.ssh/authorized_keys"
start -U tester || exit 1
sshkey "$T/id1" tester true && ok "default <home>/.ssh/authorized_keys" || bad "default authorized_keys"
stop

# --- scp (legacy protocol) through the builtin applet
start -U tester -k "$(cat "$T/id1.pub")" || exit 1
head -c 300000 /dev/urandom > "$T/files/up.bin"
SCPO=(-O -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
	-o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -P "$PORT")
mkdir -p "$T/home/dst"
# legacy scp hands the remote path to the remote shell: spaces need escaping
scp "${SCPO[@]}" "$T/files/up.bin" 'tester@127.0.0.1:dst/up\ copy.bin' && cmp -s "$T/files/up.bin" "$T/home/dst/up copy.bin" \
	&& ok "scp -O upload (escaped space in name)" || bad "scp upload"
scp "${SCPO[@]}" 'tester@127.0.0.1:dst/up\ copy.bin' "$T/files/down.bin" && cmp -s "$T/files/up.bin" "$T/files/down.bin" \
	&& ok "scp -O download" || bad "scp download"
mkdir -p "$T/files/tree/sub"; echo a > "$T/files/tree/a"; echo b > "$T/files/tree/sub/b"
scp -r "${SCPO[@]}" "$T/files/tree" "tester@127.0.0.1:dst/" && diff -r "$T/files/tree" "$T/home/dst/tree" >/dev/null \
	&& ok "scp -O -r directory" || bad "scp -r"
grep -q "^exec '$BIN' --applet scp " "$T/shell.log" && ok "server rewrote scp to builtin applet: $(grep -m1 applet "$T/shell.log")" \
	|| bad "scp not routed to builtin: $(cat "$T/shell.log")"

# --- -L local forwarding
python3 -m http.server --bind 127.0.0.1 22081 --directory "$T/files" >/dev/null 2>&1 &
HTTP=$!
sleep 1
ssh "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -N -L 22082:127.0.0.1:22081 tester@127.0.0.1 </dev/null &
FWD=$!
sleep 3
curl -s -m 10 http://127.0.0.1:22082/up.bin | cmp -s - "$T/files/up.bin" && ok "-L local port forwarding (127.0.0.1)" || bad "-L forwarding (expected to fail in noLfwd builds)"
kill $FWD 2>/dev/null; wait $FWD 2>/dev/null
ssh -o LogLevel=INFO "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -N -L 22083:localhost:22081 -L 22084:no-such-host.invalid:80 tester@127.0.0.1 </dev/null 2>"$T/fwd.err" &
FWD=$!
sleep 3
curl -s -m 10 http://127.0.0.1:22083/up.bin | cmp -s - "$T/files/up.bin" && ok "-L to 'localhost'" || bad "-L to localhost"
curl -s -m 10 http://127.0.0.1:22084/ >/dev/null 2>&1
sleep 1
grep -q "open failed" "$T/fwd.err" && ok "-L to a host name refused cleanly: $(grep -m1 'open failed' "$T/fwd.err")" \
	|| bad "-L to a host name: $(cat "$T/fwd.err")"
kill $FWD $HTTP 2>/dev/null; wait $FWD $HTTP 2>/dev/null
stop

# --- listen addresses: wildcard and IPv6 literal
"$QEMU" "$BIN" dropbear -F -E -p "$PORT" -r "$T/hostkey" -U tester -k "$(cat "$T/id1.pub")" -s "$T/shell" -D "$T/home" 2>>"$T/server.log" &
SRV=$!; sleep 2
sshkey "$T/id1" tester true && ok "-p <port> (wildcard listen)" || bad "wildcard listen"
stop
"$QEMU" "$BIN" dropbear -F -E -p "[::1]:$PORT" -r "$T/hostkey" -U tester -k "$(cat "$T/id1.pub")" -s "$T/shell" -D "$T/home" 2>>"$T/server.log" &
SRV=$!; sleep 2
ssh "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" tester@::1 'echo $SSH_CONNECTION' </dev/null 2>&1 | grep -q '^::1 ' \
	&& ok "-p [::1]:port (IPv6 literal), SSH_CONNECTION ok" || bad "IPv6 listen"
stop

# --- negotiated algorithms
start -U tester -k "$(cat "$T/id1.pub")" || exit 1
ssh -v "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" tester@127.0.0.1 true </dev/null 2>&1 \
	| grep -E "kex: algorithm|kex: host key|kex: server->client|kex: client->server" | sed 's/^debug1: /  /'
stop

echo "== server log (tail)"; tail -5 "$T/server.log"
echo "== RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
