#!/bin/sh
# Guest side of test-client-kernel34.sh: runs as /data/test.sh under the
# Linux 3.4.113 initramfs (NO /etc/passwd, /etc/group, /etc/shadow).
# The client runs as uid/gid 1000:1000 (no passwd entry) with only HOME and
# PATH in its environment. Results are printed as "M34C PASS: ..." /
# "M34C FAIL: ..." lines on the serial console, then "M34C-DONE".
# Files in /data: client kossh kdb kenc vars (PO PH PR OPW HOSTSUM)
cd /data
. /data/vars
P=0; F=0
ok()  { echo "M34C PASS: $*"; P=$((P+1)); }
bad() { echo "M34C FAIL: $*"; F=$((F+1)); }
one() { tr '\n' ' ' < "$1" | cut -c1-260; }

U=/home/u; HOST=10.0.2.2
mkdir -p $U /www; chown 1000:1000 $U; chmod 700 $U
for k in kossh kdb kenc; do cp /data/$k $U/$k; chown 1000:1000 $U/$k; chmod 600 $U/$k; done
printf 'Guest pw 34\n' > $U/pw; chown 1000:1000 $U/pw; chmod 600 $U/pw
dd if=/dev/urandom of=/www/blob bs=1024 count=1024 2>/dev/null
GSUM=$(sha256sum /www/blob | cut -d' ' -f1)
httpd -p 127.0.0.1:8080 -h /www
KDB=$(./client dropbearkey -y -f /data/kdb | grep '^ssh-ed25519')
KOS=$(cat /data/kossh.pub)

AS="chpst -u 1000:1000"
E="env -i HOME=$U PATH=/bin:/sbin:/usr/bin:/usr/sbin"
C="/data/client dbclient"
# run the client without a controlling tty, stdin at EOF
nt() { $AS $E setsid timeout "$@" </dev/null; }
# drive a prompt dialog through busybox script (pty): ptyrun OUT 'pattern|reply' ... -- cmd
ptyrun() {
	out=$1; shift; rm -f /tmp/pin $out; mkfifo /tmp/pin; chmod 666 /tmp/pin
	n=0; while [ "$1" != "--" ]; do n=$((n+1)); eval "R$n=\"\$1\""; shift; done; shift
	$AS $E script -q -c "$*" /dev/null < /tmp/pin > $out 2>&1 &
	sp=$!
	exec 7>/tmp/pin
	i=1
	while [ $i -le $n ]; do
		eval "r=\"\$R$i\""; pat=${r%%|*}; rep=${r#*|}
		t=0; while ! grep -qF "$pat" $out 2>/dev/null; do sleep 1; t=$((t+1)); [ $t -gt 180 ] && break; done
		sleep 1; printf '%s\n' "$rep" >&7
		i=$((i+1))
	done
	t=0; while kill -0 $sp 2>/dev/null; do sleep 1; t=$((t+1)); [ $t -gt 180 ] && kill $sp; done
	exec 7>&-
	rm -f /tmp/pin
}
# fetch URL until its sha256 is the expected one (or 150 s pass); prints the last sum
fetchsum() { t=0; s=""; while [ $t -lt 150 ] && [ "$s" != "$2" ]; do sleep 3; t=$((t+3)); s=$(wget -q -O - "$1" 2>/dev/null | sha256sum | cut -d' ' -f1); done; echo "$s"; }

echo "M34C: kernel $(uname -r) $(uname -m); passwd: $(ls /etc/passwd 2>&1)"
[ "$(uname -r)" = 3.4.113 ] && [ ! -e /etc/passwd ] && ok "Linux $(uname -r) $(uname -m), no /etc/passwd; client as uid 1000 via chpst" || bad "env"

# our server (the client binary's own dropbear applet), same uid
$AS env -i PATH=/bin:/usr/bin /data/client dropbear -R -F -E -p 2222 -r $U/hk -U emb -P @$U/pw -k "$KDB" -k "$KOS" -D $U >/tmp/srv.log 2>&1 &
t=0; while ! grep -q "Not backgrounding" /tmp/srv.log && [ $t -lt 60 ]; do sleep 1; t=$((t+1)); done; sleep 2

# --- the original failure: -i <OpenSSH key>
nt 300 $C -y -i $U/kossh -p $PO pwuser@$HOST 'echo OSSH-OK $(uname -m)' > /tmp/o1 2>&1; rc=$?
grep -q "OSSH-OK $HOSTARCH" /tmp/o1 && [ $rc = 0 ] && ! grep -q "String too long" /tmp/o1 \
	&& ok "host OpenSSH: -i OpenSSH-format ed25519 key logs in (was: Exited: String too long)" || bad "OpenSSH key rc=$rc: $(one /tmp/o1)"
rm -f $U/.ssh/known_hosts
# --- unknown host, no tty, stdin EOF
nt 200 $C -i $U/kdb -p $PO pwuser@$HOST true > /tmp/o2 2>&1; rc=$?
[ $rc = 1 ] && grep -q "Didn't validate host key" /tmp/o2 && ok "unknown host key, no tty, stdin EOF -> refused (rc 1), no hang" || bad "no-tty hostkey rc=$rc: $(one /tmp/o2)"
# --- host key prompt + password via pty (busybox script)
ptyrun /tmp/o3 '(y/n)|y' "password:|$OPW" -- $C -p $PO pwuser@$HOST "'echo PW-OK \$(id -un)'"
grep -q "PW-OK pwuser" /tmp/o3 && ok "host OpenSSH: host key prompt (y) + password login" || bad "password: $(one /tmp/o3)"
ls -ld $U/.ssh > /tmp/o4; kh=$(cut -c1-40 $U/.ssh/known_hosts 2>/dev/null)
grep -q "^drwx------ .* 1000 *1000 " /tmp/o4 && echo "$kh" | grep -q "^$HOST ssh-ed25519" \
	&& ok "known_hosts at \$HOME/.ssh (uid 1000, no passwd entry): $kh..." || bad "known_hosts: $(one /tmp/o4) / $kh"
nt 200 $C -i $U/kdb -p $PO pwuser@$HOST 'echo DB-OK; exit 7' > /tmp/o5 2>&1; rc=$?
[ $rc = 7 ] && grep -q DB-OK /tmp/o5 && ok "host OpenSSH: -i dropbearkey key, known host silent, exit status 7" || bad "dbkey rc=$rc: $(one /tmp/o5)"
nt 200 $C -i $U/kenc -p $PO pwuser@$HOST true > /tmp/o6 2>&1; rc=$?
[ $rc = 1 ] && grep -q "has a passphrase" /tmp/o6 && ok "passphrase-protected OpenSSH key: clear warning, no crash" || bad "kenc rc=$rc: $(one /tmp/o6)"
$AS env -i HOME=$U USER=pwuser PATH=/bin:/usr/bin setsid timeout 200 $C -i $U/kossh -p $PO $HOST 'id -un' </dev/null > /tmp/o7 2>&1
grep -qx pwuser /tmp/o7 && ok "default login name from \$USER (no passwd entry)" || bad "USER: $(one /tmp/o7)"
$AS env -i PATH=/bin:/usr/bin setsid timeout 200 $C -y -i $U/kossh -p $PO pwuser@$HOST 'echo NOHOME-OK' </dev/null > /tmp/o8 2>&1
grep -q NOHOME-OK /tmp/o8 && grep -q "not set, no passwd entry" /tmp/o8 && ok "no \$HOME: clear known_hosts warning, -y connects" || bad "no HOME: $(one /tmp/o8)"
# --- interactive pty session
ptyrun /tmp/o9 '$ |echo IA$((6*7)) $(tty)' '$ |exit' -- $C -t -i $U/kossh -p $PO pwuser@$HOST
grep -q "IA42 /dev/pts/" /tmp/o9 && ok "host OpenSSH: interactive pty session" || bad "interactive: $(one /tmp/o9)"
# --- -L: guest 127.0.0.1:9001 -> host sshd -> host 127.0.0.1:$PH
$AS $E /data/client dbclient -N -i $U/kossh -L 127.0.0.1:9001:127.0.0.1:$PH -p $PO pwuser@$HOST </dev/null >/tmp/oL 2>&1 &
LP=$!
s=$(fetchsum http://127.0.0.1:9001/blob $HOSTSUM)
[ "$s" = "$HOSTSUM" ] && ok "host OpenSSH: -L forward, 1 MiB from the host checksum OK" || bad "-L sha '$s': $(one /tmp/oL)"
kill $LP
# --- -R: host 127.0.0.1:$PR (opened by sshd) -> back to guest httpd; fetched from the guest via 10.0.2.2
$AS $E /data/client dbclient -N -i $U/kossh -R 127.0.0.1:$PR:127.0.0.1:8080 -p $PO pwuser@$HOST </dev/null >/tmp/oR 2>&1 &
RP=$!
s=$(fetchsum http://$HOST:$PR/blob $GSUM)
[ "$s" = "$GSUM" ] && ok "host OpenSSH: -R forward, guest httpd reached through sshd's listener, 1 MiB checksum OK" || bad "-R sha $s: $(one /tmp/oR)"
kill $RP
# --- scp (client mode) uses the built-in dbclient, PATH without dbclient/ssh
$AS setsid timeout 300 env -i HOME=$U PATH=/nonexistent /data/client scp -i $U/kossh -P $PO /www/blob pwuser@$HOST:up34.bin </dev/null >/tmp/os 2>&1 \
	&& $AS setsid timeout 300 env -i HOME=$U PATH=/nonexistent /data/client scp -i $U/kossh -P $PO pwuser@$HOST:up34.bin $U/down34.bin </dev/null >>/tmp/os 2>&1
[ "$(sha256sum $U/down34.bin 2>/dev/null | cut -d' ' -f1)" = "$GSUM" ] && ok "scp to/from host OpenSSH, PATH=/nonexistent (built-in dbclient)" || bad "scp host: $(one /tmp/os)"

# --- our own server in the guest
ptyrun /tmp/d1 '(y/n)|y' 'password:|Guest pw 34' -- $C -p 2222 emb@127.0.0.1 "'echo PW-OK \$(id -u)'"
grep -q "PW-OK 1000" /tmp/d1 && grep -q "^127.0.0.1 ssh-ed25519" $U/.ssh/known_hosts && ok "own server: host key y + password login, known_hosts updated" || bad "own pw: $(one /tmp/d1)"
nt 200 $C -i $U/kossh -p 2222 emb@127.0.0.1 'echo K-OK; exit 3' > /tmp/d2 2>&1; rc=$?
[ $rc = 3 ] && grep -q K-OK /tmp/d2 && ok "own server: -i OpenSSH key, exit status 3" || bad "own key rc=$rc: $(one /tmp/d2)"
ptyrun /tmp/d3 '$ |echo IA$((6*7)) $(tty)' '$ |exit' -- $C -t -i $U/kdb -p 2222 emb@127.0.0.1
grep -q "IA42 /dev/pts/" /tmp/d3 && ok "own server: interactive pty session" || bad "own interactive: $(one /tmp/d3)"
$AS $E /data/client dbclient -N -i $U/kdb -L 127.0.0.1:9002:127.0.0.1:8080 -p 2222 emb@127.0.0.1 </dev/null >/tmp/dL 2>&1 &
LP=$!
s=$(fetchsum http://127.0.0.1:9002/blob $GSUM)
[ "$s" = "$GSUM" ] && ok "own server: -L forward, 1 MiB checksum OK" || bad "own -L sha '$s': $(one /tmp/dL)"
kill $LP
nt 200 $C -i $U/kdb -R 127.0.0.1:9003:127.0.0.1:8080 -p 2222 emb@127.0.0.1 'sleep 3; echo RS-OK' > /tmp/d4 2>&1
grep -q RS-OK /tmp/d4 && grep -qi "remote tcp forward request failed" /tmp/d4 && ok "own server: -R refused (server built without it), session continues" || bad "own -R: $(one /tmp/d4)"
$AS setsid timeout 300 env -i HOME=$U PATH=/nonexistent /data/client scp -i $U/kdb -P 2222 /www/blob emb@127.0.0.1:/tmp/up-own.bin </dev/null >/tmp/d5 2>&1 \
	&& $AS setsid timeout 300 env -i HOME=$U PATH=/nonexistent /data/client scp -i $U/kdb -P 2222 emb@127.0.0.1:/tmp/up-own.bin $U/down-own.bin </dev/null >>/tmp/d5 2>&1
[ "$(sha256sum $U/down-own.bin 2>/dev/null | cut -d' ' -f1)" = "$GSUM" ] && ok "own server: scp both ways (built-in dbclient <-> built-in scp)" || bad "own scp: $(one /tmp/d5)"
echo "M34C: known_hosts: $(cut -c1-30 $U/.ssh/known_hosts | tr '\n' ' ')"

# --- -R with the key ABSENT at startup (use-after-free regression of the -r
#     string), served by this binary's own dropbear applet. 4 concurrent then
#     8 sequential dbclient connections, from source addresses 127.0.0.2,
#     ::1, 127.0.0.3, 127.0.0.1 (dbclient -b), alternating key logins and
#     refused logins (unknown user); each records the host key in its own
#     $HOME/.ssh/known_hosts. All must match the -r file; the server's cwd must
#     stay empty, the key dir hold only the 0600 key.
RK=/tmp/x/rep/ssh_host_ed25519
mkdir -p /tmp/x/rep /home/u/rcwd /tmp/rh; chown -R 1000:1000 /tmp/x /home/u/rcwd /tmp/rh; chmod 755 /tmp/x /tmp/x/rep
grep -q ' lo$' /proc/net/if_inet6 2>/dev/null && V6=1 || V6=""
if [ -n "$V6" ]; then RSRCS="127.0.0.2 ::1 127.0.0.3 127.0.0.1"; L6="-p [::1]:2229"; else RSRCS="127.0.0.2 127.0.0.3 127.0.0.1"; L6=""; fi
(cd /home/u/rcwd && exec $AS env -i PATH=/bin:/usr/bin /data/client dropbear -R -F -E -p 127.0.0.1:2229 $L6 -r $RK -U emb -k "$KDB") >/tmp/rsrv.log 2>&1 &
RSV=$!
t=0; while ! grep -q "Not backgrounding" /tmp/rsrv.log && [ $t -lt 60 ]; do sleep 1; t=$((t+1)); done; sleep 1
[ -e $RK ] && bad "-R: key existed before the first connection"
G=0
rone() { # name kind src
	h=/tmp/rh/$1; mkdir -p $h; chown 1000:1000 $h
	case $3 in *:*) dst=::1; b="";; *) dst=127.0.0.1; b="-b $3";; esac
	lu=emb; [ $2 = deny ] && lu=nosuch
	$AS env -i HOME=$h PATH=/bin:/usr/bin setsid timeout 300 /data/client dbclient -y $b -i $U/kdb -p 2229 $lu@$dst 'echo R-OK' </dev/null >$h/out 2>&1
	k=$(awk '$2=="ssh-ed25519"{print $3}' $h/.ssh/known_hosts 2>/dev/null | head -1)
	good=""; case $2 in login) grep -q R-OK $h/out && good=1;; deny) grep -q R-OK $h/out || good=1;; esac
	if [ -n "$k" ] && [ -n "$good" ]; then echo "$k" > $h/key
	else echo "ERR($2 $3): $(one $h/out)" > $h/key; fi
}
rnext() { set -- $RSRCS; n=$#; i=$((G % n + 1)); eval "SRC=\${$i}"; [ $((G % 2)) = 0 ] && KIND=login || KIND=deny; G=$((G+1)); }
pids=""
for c in c1 c2 c3 c4; do rnext; rone $c $KIND $SRC & pids="$pids $!"; done
wait $pids
for c in s1 s2 s3 s4 s5 s6 s7 s8; do rnext; rone $c $KIND $SRC; done
cat /tmp/rh/c?/key /tmp/rh/s?/key > /tmp/rkeys
FK=$(./client dropbearkey -y -f $RK 2>/dev/null | awk '$1=="ssh-ed25519"{print $2}')
nk=$(wc -l < /tmp/rkeys); nd=$(grep -v '^ERR' /tmp/rkeys | sort -u | wc -l); ne=$(grep -c '^ERR' /tmp/rkeys)
[ "$nk" = 12 ] && [ "$nd" = 1 ] && [ "$ne" = 0 ] && [ -n "$FK" ] && [ "$(head -1 /tmp/rkeys)" = "$FK" ] \
	&& ok "-R key absent at start, -r $RK: 12 dbclient connections (4 concurrent + 8), one host key = the file's" \
	|| bad "-R: n=$nk distinct=$nd errors=$ne file=$(echo $FK | cut -c1-20): $(sort /tmp/rkeys | uniq -c | cut -c1-120 | tr '\n' ' ')"
kd=$(ls -A /tmp/x/rep | tr '\n' ' '); cw=$(ls -A /home/u/rcwd | tr '\n' ' '); km=$(ls -l $RK 2>/dev/null | cut -c1-10)
kill -0 $RSV 2>/dev/null && al=yes || al=no
[ -z "$cw" ] && [ "$kd" = "ssh_host_ed25519 " ] && [ "$km" = "-rw-------" ] && [ $al = yes ] \
	&& ok "-R: server cwd empty, key dir holds only the 0600 key, server alive" || bad "-R: cwd=[$cw] keydir=[$kd] mode=$km alive=$al"
miss=""; for a in $RSRCS; do grep -q "Child connection from $a:\|Child connection from \[$a\]:" /tmp/rsrv.log || miss="$miss $a"; done
gl=$(grep -c "Generated hostkey $RK, fingerprint" /tmp/rsrv.log); go=$(grep "Generated hostkey" /tmp/rsrv.log | grep -vc "Generated hostkey $RK, fingerprint")
[ -z "$miss" ] && [ "$gl" -ge 1 ] && [ "$go" = 0 ] && ! grep -qE "Failed moving key file|Couldn't read or generate hostkey" /tmp/rsrv.log \
	&& ok "-R: log shows clients from $(echo $RSRCS | tr ' ' ','), ${gl}x Generated $RK only, no key failures" \
	|| bad "-R log: missing-src=[$miss] gen=$gl other=$go $(grep -E 'hostkey|key file' /tmp/rsrv.log | sed 's/^\[[0-9]*\] [^ ]* //' | sort | uniq -c | cut -c1-150 | head -4 | tr '\n' '|')"
kill $RSV 2>/dev/null
grep -a "Pubkey auth succeeded\|Password auth succeeded" /tmp/srv.log | sed 's/^\[[0-9]*\] [^ ]* [^ ]* /M34C: srv: /' | sort -u | head -4
echo "M34C-RESULT: $P passed, $F failed"
echo "M34C-DONE"
