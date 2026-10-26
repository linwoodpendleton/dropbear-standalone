#!/usr/bin/env bash
# dbclient acceptance for the client release asset (out/variants/dropbearmulti-client)
# under qemu-arm USER mode on an x86_64 Linux host, run as a NON-ROOT uid that
# has NO passwd entry ($HOME comes from the environment only).
#
# Servers:
#   O = the host's own OpenSSH sshd binary (/usr/sbin/sshd), started unprivileged
#       in a rootless user+mount namespace (podman unshare) with a throw-away
#       user "pwuser" (password + authorized_keys), listening on 127.0.0.1
#   D = our dropbear server (default release binary out/dropbearmulti, and the
#       server applet of the client binary itself)
#
# The client side runs in its own rootless user+mount namespace with a
# namespaced binfmt_misc entry for qemu-arm (Linux >= 6.7), so the ARM binary
# can exec itself (scp -> built-in dbclient, server -> built-in scp) exactly
# like on the board; then drops to uid/gid 4321 (no passwd entry) with setpriv.
#
# Usage: QEMU=/path/qemu-arm-static ./test-client.sh [client-binary] [server-binary]
# Needs: podman (rootless), setpriv, python3, curl, ssh-keygen, /usr/sbin/sshd.
# On a host that runs the binaries natively (ARM board, or the x86_64 ASan
# build from build.sh --asan) use QEMU=env: no binfmt_misc entry is registered.
# Run as root (e.g. on the board): NSRUN=env instead of podman unshare.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-ossh-harness.sh"
CBIN="$(readlink -f "${1:-$HERE/out/variants/dropbearmulti-client}")"
SBIN="$(readlink -f "${2:-$HERE/out/dropbearmulti}")"
QEMU="$(readlink -f "$(command -v "${QEMU:-qemu-arm-static}")")"
BASE=${BASE:-23300}
PO=$((BASE+1)); PD=$((BASE+2)); PD2=$((BASE+3)); PH=$((BASE+4))
T="$(mktemp -d /tmp/dbcli.XXXXXX)"; chmod 755 "$T"
cleanup() {
	stop_ossh "$T/ossh"
	[ -n "${HTTPD:-}" ] && kill "$HTTPD" 2>/dev/null
	sleep 0.5
	[ -n "${KEEP:-}" ] && { echo "kept $T"; return; }
	$NSRUN rm -rf "$T" 2>/dev/null || rm -rf "$T"
}
trap cleanup EXIT

# ------------------------------------------------------------------ fixtures
mkdir -p "$T/bin" "$T/keys" "$T/www"
cp "$CBIN" "$T/bin/client"; cp "$SBIN" "$T/bin/server"; chmod 755 "$T/bin"/*
head -c 1048576 /dev/urandom > "$T/www/blob"
BLOBSUM=$(sha256sum < "$T/www/blob" | cut -d' ' -f1)
"$QEMU" "$T/bin/client" dropbearkey -t ed25519 -f "$T/keys/kdb" 2>/dev/null | grep '^ssh-ed25519' > "$T/keys/kdb.pub"
ssh-keygen -q -t ed25519 -N '' -C ossh-key -f "$T/keys/kossh"
ssh-keygen -q -t ed25519 -N 'secret phrase' -C ossh-enc -f "$T/keys/kenc"
ssh-keygen -q -t rsa -b 2048 -N '' -C ossh-rsa -f "$T/keys/krsa"
head -c 300 /dev/urandom > "$T/keys/kjunk"
cat "$T/keys/kdb.pub" "$T/keys/kossh.pub" > "$T/keys/ak"
chmod 644 "$T/keys"/*

# OpenSSH sshd (host binary), unprivileged
O="$T/ossh"; OPW='Open pw 7!'
start_ossh "$O" "$PO" "$OPW" "$T/keys/ak" || { echo "cannot start OpenSSH sshd"; exit 1; }
python3 -m http.server --bind 127.0.0.1 --directory "$T/www" "$PH" >/dev/null 2>&1 &
HTTPD=$!
for p in $PO $PH; do for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null && break; sleep 0.2; done; done

# pty driver: ptyrun.py TIMEOUT 'pattern=>reply' ... -- cmd args
# (a reply is sent every time its pattern shows up in new output; \n in reply = Enter)
cat > "$T/bin/ptyrun.py" <<'EOF'
import os, pty, sys, time, select
a = sys.argv[1:]; tmo = float(a.pop(0)); i = a.index('--')
rules = [r.split('=>', 1) for r in a[:i]]; cmd = a[i+1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out = b''; seen = {}; end = time.time() + tmo
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
    for n, (pat, rep) in enumerate(rules):
        p = pat.encode(); k = out.count(p)
        if k > seen.get(n, 0):
            seen[n] = k; time.sleep(0.3)
            os.write(fd, rep.encode().decode('unicode_escape').encode())
else:
    os.kill(pid, 9)
sys.stdout.write(out.decode('utf-8', 'replace').replace('\r', ''))
_, st = os.waitpid(pid, 0)
sys.exit(124 if time.time() >= end else (os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st)))
EOF

# ------------------------------------------------------------------ client side
cat > "$T/bin/inner.sh" <<'INNER'
#!/bin/bash
# runs as uid 4321 (no passwd entry), binfmt_misc qemu-arm registered
set -u
T=$1; PO=$2; PD=$3; PD2=$4; PH=$5; BLOBSUM=$6; OPW=$7
B=$T/bin/client; S=$T/bin/server; H=$T/h
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
umask 077; mkdir -p $H $T/ch; cd $H
for k in kdb kossh kenc krsa kjunk ak; do cp $T/keys/$k $H/$k; done
# client environment: only PATH and HOME (no USER/LOGNAME), PATH has no dbclient/ssh
E=(env -i PATH=/usr/bin:/bin HOME=$H)
dbc() { timeout 120 "${E[@]}" $B dbclient "$@"; }
pty() { local t=$1; shift; timeout 150 "${E[@]}" python3 $T/bin/ptyrun.py "$t" "$@"; }
waitport() { for _ in $(seq 100); do (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null && return 0; sleep 0.3; done; return 1; }
blobsum() { curl -s --max-time 120 "http://127.0.0.1:$1/blob" | sha256sum | cut -d' ' -f1; }

[ "$(id -u):$(id -g)" = "4321:4321" ] && ! getent passwd 4321 >/dev/null && ! grep -q ':4321:' /etc/passwd \
	&& ok "client runs as uid 4321 with no passwd entry; binfmt: $(head -1 /proc/sys/fs/binfmt_misc/qemu-arm 2>/dev/null || echo 'none (runs natively)')" \
	|| bad "identity: $(id)"
# the original bug: dbclient -i <OpenSSH key> -> "Exited: String too long"
out=$(setsid -w "${E[@]}" $B dbclient -y -i $H/kossh -p $PO pwuser@127.0.0.1 'echo OSSHKEY-OK' </dev/null 2>&1); rc=$?
echo "  > $(echo "$out" | tr '\n' ' ')"
[ $rc = 0 ] && echo "$out" | grep -q OSSHKEY-OK && ! echo "$out" | grep -q "String too long" \
	&& ok "O: -i OpenSSH-format ed25519 key (ssh-keygen) logs in (was: Exited: String too long)" || bad "O: OpenSSH key rc=$rc"
rm -f $H/.ssh/known_hosts

# ---------------- O: host OpenSSH sshd
out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -i $H/kdb -p $PO pwuser@127.0.0.1 true </dev/null 2>&1); rc=$?
[ $rc != 0 ] && [ $rc != 124 ] && echo "$out" | grep -q "Didn't validate host key" \
	&& ok "O: unknown host key, no tty, stdin at EOF -> refused promptly (rc=$rc), no endless loop" || bad "O: no-tty hostkey rc=$rc: $out"
[ ! -e $H/.ssh/known_hosts ] || [ ! -s $H/.ssh/known_hosts ] && ok "O: refused host key not written to known_hosts" || bad "O: known_hosts written after refusal"
out=$(pty 90 'continue connecting? (y/n)=>y\n' "password:=>$OPW\n" -- $B dbclient -p $PO pwuser@127.0.0.1 'echo PW-OK $(id -un) $(id -u)' 2>&1); rc=$?
echo "  > $(echo "$out" | tail -2 | tr '\n' ' ')"
echo "  > $(echo "$out" | tr '\n' ' ' | cut -c1-300)"
[ $rc = 0 ] && echo "$out" | grep -q "PW-OK pwuser 2000" && ok "O: host key prompt answered y + password login, exec command" || bad "O: password rc=$rc"
kh=$(cat $H/.ssh/known_hosts 2>/dev/null)
[ "$(stat -c %a $H/.ssh)" = 700 ] && echo "$kh" | grep -q "^127.0.0.1 ssh-ed25519 AAAA" \
	&& ok "O: known_hosts created at \$HOME/.ssh/known_hosts (\$HOME from env, no passwd entry): $(echo "$kh" | cut -c1-40)..." || bad "O: known_hosts: $kh"
out=$(pty 90 "password:=>wrong pw\n" -- $B dbclient -p $PO pwuser@127.0.0.1 'echo SHOULD-NOT' 2>&1); rc=$?
[ $rc != 0 ] && ! echo "$out" | grep -q SHOULD-NOT && ok "O: wrong password rejected (rc=$rc): $(echo "$out" | tail -1)" || bad "O: wrong password rc=$rc: $out"
out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -i $H/kdb -p $PO pwuser@127.0.0.1 'echo DBKEY-OK' </dev/null 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q DBKEY-OK && ! echo "$out" | grep -qi "host key" \
	&& ok "O: -i dropbearkey key; known host accepted silently (no tty)" || bad "O: dropbear key rc=$rc: $out"
out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -i $H/kossh -p $PO pwuser@127.0.0.1 'echo X >&2; exit 7' </dev/null 2>&1); rc=$?
[ $rc = 7 ] && echo "$out" | grep -q '^X' && ok "O: remote exit status 7 and stderr passed through" || bad "O: exit status rc=$rc"
s=$(setsid -w "${E[@]}" timeout 120 $B dbclient -i $H/kossh -p $PO pwuser@127.0.0.1 'sha256sum' < $T/www/blob 2>/dev/null | cut -d' ' -f1)
[ "$s" = "$BLOBSUM" ] && ok "O: 1 MiB stdin -> remote sha256 matches" || bad "O: stdin sha $s"
out=$(pty 90 '$ =>echo IA$((6*7)) $(tty); exit 3\n' -- $B dbclient -t -i $H/kossh -p $PO pwuser@127.0.0.1 2>&1); rc=$?
echo "$out" | grep -q "IA42 /dev/pts/" && [ $rc = 3 ] && ok "O: interactive pty session (-t): $(echo "$out" | grep -o 'IA42 /dev/pts/[0-9]*' | head -1), exit 3" || bad "O: interactive rc=$rc: $out"
for f in kenc:"passphrase" krsa:"only ed25519" kjunk:"not a Dropbear or OpenSSH private key"; do
	k=${f%%:*}; m=${f#*:}
	out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -i $H/$k -p $PO pwuser@127.0.0.1 true </dev/null 2>&1); rc=$?
	echo "$out" | grep -q "Failed loading keyfile '$H/$k': .*$m" && ! echo "$out" | grep -q "String too long" && [ $rc = 1 ] \
		&& ok "O: -i $k -> warning '$(echo "$out" | grep -o "$m[^(]*" | head -1 | cut -c1-60)', then rc 1 (no tty for password)" || bad "O: -i $k rc=$rc: $out"
done
out=$(setsid -w env -i PATH=/usr/bin:/bin HOME=$H USER=pwuser timeout 60 $B dbclient -i $H/kossh -p $PO 127.0.0.1 'id -un' </dev/null 2>&1)
echo "$out" | grep -qx pwuser && ! echo "$out" | grep -q "failed to identify" \
	&& ok "O: default login name from \$USER when the uid has no passwd entry" || bad "O: USER default: $out"
out=$(setsid -w env -i PATH=/usr/bin:/bin timeout 60 $B dbclient -y -i $H/kossh -p $PO pwuser@127.0.0.1 'echo NOHOME-OK' </dev/null 2>&1)
echo "$out" | grep -q NOHOME-OK && echo "$out" | grep -q 'not set, no passwd entry' \
	&& ok "O: no \$HOME and no passwd entry: clear known_hosts warning, -y still connects" || bad "O: no HOME: $out"
# -L
"${E[@]}" $B dbclient -N -i $H/kossh -L 127.0.0.1:$((PD+10)):127.0.0.1:$PH -p $PO pwuser@127.0.0.1 </dev/null >$T/ch/L.log 2>&1 &
LP=$!
if waitport $((PD+10)); then
	s=$(blobsum $((PD+10)))
	for i in 1 2 3 4; do blobsum $((PD+10)) > $T/ch/par$i & done; wait $(jobs -p | grep -v "^$LP$") 2>/dev/null
	n=$(cat $T/ch/par? | grep -c "^$BLOBSUM$")
	[ "$s" = "$BLOBSUM" ] && [ "$n" = 4 ] && ok "O: -L local forward, 1 MiB + 4 parallel transfers checksum OK" || bad "O: -L sha $s par $n"
else bad "O: -L listener did not come up: $(cat $T/ch/L.log)"; fi
kill $LP 2>/dev/null
# -R
"${E[@]}" $B dbclient -N -i $H/kossh -R 127.0.0.1:$((PD+11)):127.0.0.1:$PH -p $PO pwuser@127.0.0.1 </dev/null >$T/ch/R.log 2>&1 &
RP=$!
if waitport $((PD+11)); then
	s=$(blobsum $((PD+11)))
	[ "$s" = "$BLOBSUM" ] && ok "O: -R remote forward (listener opened by sshd), 1 MiB checksum OK" || bad "O: -R sha $s"
else bad "O: -R listener did not come up: $(cat $T/ch/R.log)"; fi
kill $RP 2>/dev/null
# scp (client mode) -> built-in dbclient, nothing named dbclient/ssh in PATH
mkdir -p $T/ch/scp
out=$(setsid -w timeout 120 env -i PATH=/nonexistent HOME=$H $B scp -i $H/kossh -P $PO $T/www/blob pwuser@127.0.0.1:up.bin </dev/null 2>&1); rc1=$?
out2=$(setsid -w timeout 120 env -i PATH=/nonexistent HOME=$H $B scp -i $H/kossh -P $PO pwuser@127.0.0.1:up.bin $T/ch/scp/down.bin </dev/null 2>&1); rc2=$?
[ $rc1 = 0 ] && [ $rc2 = 0 ] && [ "$(sha256sum < $T/ch/scp/down.bin | cut -d' ' -f1)" = "$BLOBSUM" ] \
	&& ok "O: scp upload + download 1 MiB with PATH=/nonexistent (scp runs the built-in dbclient)" || bad "O: scp rc=$rc1/$rc2: $out $out2"

# ---------------- D: our dropbear server (release binary), as the same uid
mkdir -p $H/srvhome
# inline -k keys: inside this user namespace "/" and "/tmp" are owned by the
# overflow uid (host root is unmapped), so -K's directory-ownership walk can't pass
K1=$(cat $T/keys/kdb.pub); K2=$(cat $T/keys/kossh.pub)
env -i PATH=/usr/bin:/bin DROPBEAR_PASSWORD='Emb pw 9' $S dropbear -R -F -E -p 127.0.0.1:$PD -r $H/srv_hk \
	-U emb -k "$K1" -k "$K2" -D $H/srvhome -s /bin/sh 2>$T/ch/srv.log &
SP=$!
env -i PATH=/usr/bin:/bin DROPBEAR_PASSWORD='Cli pw 9' $B dropbear -R -F -E -p 127.0.0.2:$PD2 -r $H/srv_hk2 \
	-U emb -k "$K1" -k "$K2" -D $H/srvhome -s /bin/sh 2>$T/ch/srv2.log &
SP2=$!
waitport $PD; for _ in $(seq 100); do (exec 3<>/dev/tcp/127.0.0.2/$PD2) 2>/dev/null && break; sleep 0.3; done
out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -i $H/kossh -p $PD emb@127.0.0.1 'echo MISMATCH-NOT-DETECTED' </dev/null 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -qi "mismatch" && ! echo "$out" | grep -q MISMATCH-NOT-DETECTED \
	&& ok "D: known_hosts has 127.0.0.1 = OpenSSH key -> our server's key is a host key MISMATCH, refused" || bad "D: mismatch rc=$rc: $out"
out=$(pty 90 'continue connecting? (y/n)=>y\n' "password:=>Emb pw 9\n" -- $B dbclient -p $PD emb@localhost 'echo PW-OK $(id -u) HOME=$HOME' 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q "PW-OK 4321 HOME=$H/srvhome" && grep -q "^localhost ssh-ed25519" $H/.ssh/known_hosts \
	&& ok "D: 'localhost' (resolved by this DNS-enabled build): host key y + password login, known_hosts entry added" || bad "D: password rc=$rc: $out"
for k in kdb kossh; do
	out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -i $H/$k -p $PD emb@localhost 'echo KEY-OK; exit 5' </dev/null 2>&1); rc=$?
	[ $rc = 5 ] && echo "$out" | grep -q KEY-OK && ok "D: -i $k login, exit status 5" || bad "D: -i $k rc=$rc: $out"
done
out=$(pty 90 '$ =>echo IA$((6*7)) $(tty); exit\n' -- $B dbclient -t -i $H/kdb -p $PD emb@localhost 2>&1); rc=$?
echo "$out" | grep -q "IA42 /dev/pts/" && [ $rc = 0 ] && ok "D: interactive pty session" || bad "D: interactive rc=$rc: $out"
"${E[@]}" $B dbclient -N -i $H/kdb -L 127.0.0.1:$((PD+12)):127.0.0.1:$PH -p $PD emb@localhost </dev/null >$T/ch/L2.log 2>&1 &
LP=$!
if waitport $((PD+12)); then
	s=$(blobsum $((PD+12))); [ "$s" = "$BLOBSUM" ] && ok "D: -L local forward through our server, 1 MiB checksum OK" || bad "D: -L sha $s"
else bad "D: -L listener: $(cat $T/ch/L2.log)"; fi
kill $LP 2>/dev/null
out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -i $H/kdb -R 127.0.0.1:$((PD+13)):127.0.0.1:$PH -p $PD emb@localhost 'sleep 2; echo R-SESSION-OK' </dev/null 2>&1)
echo "$out" | grep -q R-SESSION-OK && echo "$out" | grep -qi "remote tcp forward request failed" \
	&& ok "D: -R refused by our server (not built in), client warns and the session still works" || bad "D: -R: $out"
out=$(setsid -w timeout 120 env -i PATH=/nonexistent HOME=$H $B scp -i $H/kdb -P $PD $T/www/blob emb@localhost:up2.bin </dev/null 2>&1); rc1=$?
out2=$(setsid -w timeout 120 env -i PATH=/nonexistent HOME=$H $B scp -i $H/kdb -P $PD emb@localhost:up2.bin $T/ch/scp/down2.bin </dev/null 2>&1); rc2=$?
[ $rc1 = 0 ] && [ $rc2 = 0 ] && [ "$(sha256sum < $T/ch/scp/down2.bin | cut -d' ' -f1)" = "$BLOBSUM" ] \
	&& ok "D: scp both ways, built-in dbclient <-> server's built-in scp, PATH=/nonexistent" || bad "D: scp rc=$rc1/$rc2: $out $out2"
out=$(setsid -w "${E[@]}" timeout 60 $B dbclient -y -i $H/kossh -p $PD2 emb@127.0.0.2 'echo SELF-OK' </dev/null 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q SELF-OK && ok "D: client binary's own server applet + its dbclient (key login)" || bad "D: self server rc=$rc: $out"
kill $SP $SP2 2>/dev/null
grep -q "Emb pw\|Cli pw" $T/ch/srv.log $T/ch/srv2.log && bad "D: password in server log" || true
echo "== known_hosts:"; cut -c1-60 $H/.ssh/known_hosts | sed 's/^/  /'
echo "== INNER RESULT: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
INNER
chmod 755 "$T/bin/inner.sh" "$T/bin/ptyrun.py"

echo "== client $(sha256sum < "$CBIN" | cut -c1-16)…  server $(sha256sum < "$SBIN" | cut -c1-16)…  sshd: $(/usr/sbin/sshd -V 2>&1 | head -1 || true)$(ssh -V 2>&1)"
# binfmt_misc only when the kernel can't exec the binary itself (126 = ENOEXEC)
"$CBIN" dropbear -V >/dev/null 2>&1; [ $? -ne 126 ] && NATIVE=1 || NATIVE=0
$NSRUN unshare -m bash -c "
	if [ $NATIVE = 0 ]; then
	mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || exit 90
	printf '%s' ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:$QEMU:PF' \
		> /proc/sys/fs/binfmt_misc/register || exit 91
	fi
	chown 4321:4321 $T
	exec setpriv --reuid 4321 --regid 4321 --clear-groups --inh-caps=-all /bin/bash $T/bin/inner.sh '$T' $PO $PD $PD2 $PH $BLOBSUM '$OPW'
"
RC=$?
echo "== OpenSSH sshd log (auth lines):"; $NSRUN grep -E "Accepted|Failed password|forward|error|fatal|pty" "$O/sshd.log" 2>/dev/null | sed 's/^.*sshd\[[0-9]*\]: /  /' | sort | uniq -c | head -12
exit $RC
