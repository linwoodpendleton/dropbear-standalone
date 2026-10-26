#!/usr/bin/env bash
# Independent acceptance matrix for out/dropbearmulti under qemu-arm USER mode,
# run as an ordinary (non-root) user, driven by the host's OpenSSH client.
# Complements test-qemu.sh; follows the acceptance spec literally:
#   dropbear -R -F -E -p <port> -U <user> -H <hash>   (no -s / -D: defaults
#   must come from $SHELL / $HOME because <user> has no /etc/passwd entry)
# then -P, -k, -K separately.
#
# Usage: QEMU=/path/qemu-arm-static ./test-matrix-user.sh [binary]
#   On an ARM host that runs the binary natively, or for a host-native ASan
#   build (build.sh --asan): QEMU=env ./test-matrix-user.sh <binary>
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-hostkey-rep.sh"
BIN="$(readlink -f "${1:-$HERE/out/dropbearmulti}")"
QEMU="${QEMU:-qemu-arm-static}"
PORT=${PORT:-2222}
U=nkemb$$                      # a login name that is NOT in /etc/passwd
T="$(mktemp -d /tmp/dbmx.XXXXXX)"
PASS=0; FAIL=0; RES=()
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); RES+=("PASS|$*"); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); RES+=("FAIL|$*"); }
getent passwd "$U" >/dev/null && { echo "user $U unexpectedly exists"; exit 2; }
[ "$(id -u)" != 0 ] || { echo "run as a non-root user"; exit 2; }

mkdir -p "$T/home" "$T/files"; chmod 755 "$T/home"
cat > "$T/askpass" <<'EOF'
#!/bin/sh
cat "$ASKPASS_FILE"
EOF
chmod 755 "$T/askpass"
# scp wrapper shell: without binfmt_misc the host kernel can't exec the ARM
# binary that the server's builtin-scp rewrite execs, so route it via qemu.
cat > "$T/scpsh" <<EOF
#!/bin/sh
if [ "\$1" = "-c" ]; then
	cmd=\$(printf '%s' "\$2" | sed "s#^exec '$BIN' --applet#exec $QEMU '$BIN' --applet#")
	exec /bin/sh -c "\$cmd"
fi
exec /bin/sh "\$@"
EOF
chmod 755 "$T/scpsh"
ssh-keygen -q -t ed25519 -N '' -C mx1 -f "$T/id1"
ssh-keygen -q -t ed25519 -N '' -C mx2 -f "$T/id2"
ssh-keygen -q -t ed25519 -N '' -C mx3 -f "$T/id3"
H6=$(openssl passwd -6 -salt 'Mx6salt' 'Six pass!')
H5=$(openssl passwd -5 -salt 'Mx5salt' 'Five pass?')

KH="$T/known_hosts"
SSHO=(-F /dev/null -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=accept-new
	-o LogLevel=ERROR -o ConnectTimeout=20 -p "$PORT")
sshpw() { # password user ssh-args...
	local pw="$1" u="$2"; shift 2
	printf '%s\n' "$pw" > "$T/pw"
	ASKPASS_FILE="$T/pw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
		setsid -w ssh "${SSHO[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
		-o NumberOfPasswordPrompts=1 "$u@127.0.0.1" "$@" </dev/null
}
sshkey() { # keyfile user ssh-args...
	local k="$1" u="$2"; shift 2
	ssh "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$k" "$u@127.0.0.1" "$@" </dev/null
}
SRV=""
start() { # env-assignments... -- server args...
	stop
	local envs=()
	while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
	env -i PATH=/usr/bin:/bin "${envs[@]}" "$QEMU" "$BIN" dropbear -R -F -E -p "127.0.0.1:$PORT" "$@" 2>>"$T/server.log" &
	SRV=$!
	for _ in $(seq 60); do
		(exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && return 0
		sleep 0.2
	done
	echo "server did not start"; tail -5 "$T/server.log"; return 1
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
trap 'stop; kill $(jobs -p) 2>/dev/null; rm -rf "$T"; [ -n "${REPX:-}" ] && rm -rf /tmp/x' EXIT

echo "== binary $(sha256sum "$BIN" | cut -c1-16)... as uid $(id -u) ($(id -un)), login name '$U' (no passwd entry)"

# ---------------------------------------------------------------- -H $6$
start HOME="$T/home" SHELL=/bin/bash -- -r "$T/hostkey" -U "$U" -H "$H6" || exit 1
out=$(sshpw 'Six pass!' "$U" 'echo "OK id=$(id -u) USER=$USER LOGNAME=$LOGNAME HOME=$HOME SHELL=$SHELL PWD=$PWD"' 2>&1)
echo "  > $out"
echo "$out" | grep -q "^OK id=$(id -u) USER=$U LOGNAME=$U HOME=$T/home SHELL=/bin/bash PWD=$T/home$" \
	&& ok "H6 password login; user w/o passwd entry synthesized from getuid/\$HOME/\$SHELL" || bad "H6 login/env: $out"
[ -f "$T/hostkey" ] && [ "$(stat -c %a "$T/hostkey")" = 600 ] && ok "-R -r: host key created in -r file, mode 0600" \
	|| bad "-R host key file: $(ls -l "$T/hostkey" 2>&1)"
FP1=$(ssh-keygen -lf "$KH" 2>/dev/null | awk '{print $2}')
sshpw 'Six pass?' "$U" true >/dev/null 2>&1 && bad "H6 wrong password accepted" || ok "H6 wrong password rejected"
sshpw 'six pass!' "$U" true >/dev/null 2>&1 && bad "H6 case-changed password accepted" || ok "H6 case-changed password rejected"
sshpw '' "$U" true >/dev/null 2>&1 && bad "H6 empty password accepted" || ok "H6 empty password rejected"
sshpw 'Six pass!' root true >/dev/null 2>&1 && bad "wrong user 'root' accepted" || ok "wrong user (root) rejected, right password"
sshpw 'Six pass!' "$(id -un)" true >/dev/null 2>&1 && bad "real account name accepted" || ok "wrong user (real uid name $(id -un)) rejected"
sshpw 'Six pass!' "${U}x" true >/dev/null 2>&1 && bad "user-name suffix accepted" || ok "wrong user (name+suffix) rejected"
sshkey "$T/id1" "$U" true 2>/dev/null && bad "pubkey accepted w/o configured keys" || ok "no -k/-K + no ~/.ssh/authorized_keys -> pubkey rejected"
# exec: exit status, stderr, stdin passthrough of 1 MB binary
sshpw 'Six pass!' "$U" 'echo to-stderr >&2; exit 7' >/dev/null 2>"$T/err"; rc=$?
[ $rc = 7 ] && grep -q to-stderr "$T/err" && ok "exec: exit status 7 + stderr propagated" || bad "exec status rc=$rc $(cat "$T/err")"
head -c 1048576 /dev/urandom > "$T/files/blob"
printf '%s\n' 'Six pass!' > "$T/pw"
h=$(ASKPASS_FILE="$T/pw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHO[@]}" \
	-o PubkeyAuthentication=no "$U@127.0.0.1" 'sha256sum' < "$T/files/blob" 2>/dev/null | cut -c1-64)
[ "$h" = "$(sha256sum < "$T/files/blob" | cut -c1-64)" ] && ok "exec: 1 MiB stdin -> remote sha256sum matches" || bad "stdin passthrough ($h)"
# max auth tries: one connection, many wrong passwords -> disconnected
printf 'bad\n' > "$T/pw"
t0=$(date +%s)
ASKPASS_FILE="$T/pw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh -F /dev/null \
	-o UserKnownHostsFile="$KH" -o LogLevel=INFO -p "$PORT" -o PubkeyAuthentication=no \
	-o PreferredAuthentications=password -o NumberOfPasswordPrompts=20 "$U@127.0.0.1" true </dev/null >/dev/null 2>"$T/err"
t1=$(date +%s)
n=$(grep -c "Permission denied" "$T/err")
d=$(grep -iE "too many|disconnect|connection closed" "$T/err" | tr -d '\r' | head -1)
[ -n "$d" ] && [ "$n" -le 10 ] && [ $((t1-t0)) -ge 2 ] \
	&& ok "rate limit: client allowed 20 tries, server cut it off after $n failures in $((t1-t0))s ($d; $(grep -m1 'Max auth tries' "$T/server.log" | cut -d' ' -f4-))" \
	|| bad "rate limit: $(cat "$T/err") $((t1-t0))s"
stop
cp "$T/hostkey" "$T/hostkey.first"

# ------------------------------------------- host key persistence across restart
start HOME="$T/home" SHELL=/bin/sh -- -r "$T/hostkey" -U "$U" -H "$H6" || exit 1
SSHO_STRICT=(-F /dev/null -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -o LogLevel=ERROR -p "$PORT")
printf '%s\n' 'Six pass!' > "$T/pw"
ASKPASS_FILE="$T/pw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHO_STRICT[@]}" \
	-o PubkeyAuthentication=no "$U@127.0.0.1" true </dev/null 2>"$T/err" \
	&& cmp -s "$T/hostkey" "$T/hostkey.first" \
	&& ok "host key persisted: restart reuses -r file, StrictHostKeyChecking=yes passes ($FP1)" \
	|| bad "host key persistence: $(cat "$T/err")"
stop
start HOME="$T/home" -- -r "$T/hostkey2" -U "$U" -H "$H6" || exit 1
ASKPASS_FILE="$T/pw" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w ssh "${SSHO_STRICT[@]}" \
	-o PubkeyAuthentication=no "$U@127.0.0.1" true </dev/null 2>"$T/err" \
	&& bad "different -r file but same host key?" \
	|| { grep -q "HOST IDENTIFICATION HAS CHANGED" "$T/err" && ok "control: new -r file -> new key, client detects change"; } \
	|| bad "control: $(cat "$T/err")"
stop

# ---------------------------------------------------------------- -H $5$
start HOME="$T/home" -- -r "$T/hostkey" -U "$U" -H "$H5" || exit 1
sshpw 'Five pass?' "$U" true && ok "H5 password login" || bad "H5 login"
sshpw 'Five pass!' "$U" true 2>/dev/null && bad "H5 wrong password accepted" || ok "H5 wrong password rejected"
stop
# rounds < 1000 must be refused at startup (otherwise nobody could ever log in)
# (well-formed $6$ hash with rounds=500 inserted; openssl passwd has no rounds option)
HR=$(openssl passwd -6 -salt abcdefgh x | sed 's/^\$6\$/$6$rounds=500$/')
timeout 15 env -i "$QEMU" "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" -r "$T/hostkey" -U "$U" -H "$HR" 2>&1 | grep -q "Unsupported -H" \
	&& ok "-H with rounds=500 refused at startup" || bad "-H rounds=500 not refused"
timeout 15 env -i "$QEMU" "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" -r "$T/hostkey" -U "$U" -H '$6$abc$tooshort' 2>&1 | grep -q "Unsupported -H" \
	&& ok "-H truncated hash refused at startup" || bad "truncated -H not refused"

# ---------------------------------------------------------------- -P plaintext
start HOME="$T/home" -- -r "$T/hostkey" -U "$U" -P "pl ain'\"\$pw" || exit 1
sshpw "pl ain'\"\$pw" "$U" true && ok "-P password with quotes/space/\$ login" || bad "-P login"
sshpw "pl ain'\"\$p" "$U" true 2>/dev/null && bad "-P prefix accepted" || ok "-P prefix rejected"
sshpw "pl ain'\"\$pw" nobody true 2>/dev/null && bad "-P wrong user accepted" || ok "-P wrong user rejected"
stop
timeout 15 env -i "$QEMU" "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" -r "$T/hostkey" -U "$U" -P '' 2>&1 | grep -q "Empty password" \
	&& ok "-P '' refused at startup" || bad "-P '' not refused"

# ---------------------------------------------------------------- -k / -K
start HOME="$T/home" -- -r "$T/hostkey" -U "$U" -k "$(cat "$T/id1.pub")" -k "$(cat "$T/id2.pub")" || exit 1
sshkey "$T/id1" "$U" true && sshkey "$T/id2" "$U" true && ok "-k x2 (repeatable): both keys accepted" || bad "-k x2"
sshkey "$T/id3" "$U" true 2>/dev/null && bad "-k: unlisted key accepted" || ok "-k: unlisted key rejected"
sshkey "$T/id1" root true 2>/dev/null && bad "-k: wrong user accepted" || ok "-k: right key, wrong user rejected"
sshpw x "$U" true 2>/dev/null && bad "password auth offered w/o -P/-H" || ok "-k only: password auth not offered"
stop
cat "$T/id3.pub" > "$T/ak"; echo "# comment" >> "$T/ak"; echo "" >> "$T/ak"; cat "$T/id2.pub" >> "$T/ak"; chmod 600 "$T/ak"
start HOME="$T/home" -- -r "$T/hostkey" -U "$U" -K "$T/ak" || exit 1
sshkey "$T/id3" "$U" true && sshkey "$T/id2" "$U" true && ok "-K file (comments/blank lines), keys on lines 1 and 4" || bad "-K"
sshkey "$T/id1" "$U" true 2>/dev/null && bad "-K: unlisted key accepted" || ok "-K: unlisted key rejected"
cat "$T/id1.pub" >> "$T/ak"
sshkey "$T/id1" "$U" true && ok "-K file re-read per login (key appended while running)" || bad "-K not re-read"
stop

# ---------------------------------------------------------- pty / interactive
start HOME="$T/home" SHELL=/bin/sh -- -r "$T/hostkey" -U "$U" -k "$(cat "$T/id1.pub")" || exit 1
cat > "$T/ptydrive.py" <<'EOF'
import os, pty, sys, time, select, fcntl, termios, struct
argv = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 37, 113, 0, 0))
    os.execvp(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 37, 113, 0, 0))
buf = b""
def rd(t):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: d = os.read(fd, 4096)
            except OSError: return False
            if not d: return False
            buf += d
    return True
def until(s, t=20):
    end = time.time() + t
    while s.encode() not in buf and time.time() < end:
        if not rd(0.3): break
    return s.encode() in buf
until("$ ", 25) or until("# ", 1)
os.write(fd, b"echo TTY=$(tty) SIZE=$(stty size) TERM=$TERM; echo M$((6*7))M\n"); until("M42M")
os.write(fd, b"sleep 30; echo SLEPT\n"); time.sleep(2)
os.write(fd, b"\x03"); time.sleep(1)                # Ctrl-C -> SIGINT via the pty
os.write(fd, b"echo AFTER-INT\n"); until("AFTER-INT\r\n", 10)
os.write(fd, b"exit 5\n"); rd(3)
_, st = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
print("\nEXIT=%d" % os.waitstatus_to_exitcode(st))
EOF
out=$(TERM=xterm-256color python3 -I "$T/ptydrive.py" ssh "${SSHO[@]}" -tt -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" "$U@127.0.0.1" 2>&1)
echo "$out" | tr -d '\r' | grep -E "TTY=|^M42M|EXIT=|SLEPT" | sed 's/^/  > /'
echo "$out" | grep -q "TTY=/dev/pts/[0-9]* SIZE=37 113 TERM=xterm-256color" && ok "pty: /dev/pts/N, window size 37x113 and TERM passed" || bad "pty basics"
echo "$out" | grep -q "^M42M" && ok "pty: interactive command executed" || bad "pty exec"
o2=$(echo "$out" | tr -d '\r')
echo "$o2" | grep -qx "SLEPT" && bad "Ctrl-C did not interrupt sleep" || { echo "$o2" | grep -qx "AFTER-INT" && ok "pty: Ctrl-C delivered SIGINT to foreground job (sleep 30 interrupted)"; } || bad "Ctrl-C"
echo "$out" | grep -q "EXIT=5" && ok "pty: shell exit status 5 propagated" || bad "pty exit status"
stop

# ---------------------------------------------------------------- -L forwarding
start HOME="$T/home" SHELL="$T/scpsh" -- -r "$T/hostkey" -U "$U" -k "$(cat "$T/id1.pub")" || exit 1
python3 -m http.server --bind 127.0.0.1 22191 --directory "$T/files" >/dev/null 2>&1 &
HTTP=$!; sleep 1
ssh "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -N -L 22192:127.0.0.1:22191 "$U@127.0.0.1" </dev/null >/dev/null 2>&1 &
FWD=$!; sleep 3
curl -s -m 20 http://127.0.0.1:22192/blob | cmp -s - "$T/files/blob" && ok "-L 22192:127.0.0.1:22191, 1 MiB over the tunnel" || bad "-L"
for i in 1 2 3 4; do curl -s -m 20 -o "$T/par$i" http://127.0.0.1:22192/blob & done; wait $(jobs -p | grep -vE "^($HTTP|$FWD|$SRV)$") 2>/dev/null
c=0; for i in 1 2 3 4; do cmp -s "$T/par$i" "$T/files/blob" && c=$((c+1)); done
[ $c = 4 ] && ok "-L: 4 parallel channels intact" || bad "-L parallel ($c/4)"
kill $FWD 2>/dev/null; wait $FWD 2>/dev/null
# remote forwarding is not built in: -R must be refused, not silently half-work
ssh "${SSHO[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -o ExitOnForwardFailure=yes -N -R 22193:127.0.0.1:22191 "$U@127.0.0.1" </dev/null >/dev/null 2>&1 &
RF=$!; sleep 4
if kill -0 $RF 2>/dev/null; then bad "-R remote forward accepted (not expected in this build)"; kill $RF; else ok "ssh -R remote forward refused (not built in)"; fi
wait $RF 2>/dev/null

# ---------------------------------------------------------------- scp -O
mkdir -p "$T/home/up"
scp -O -F /dev/null -o UserKnownHostsFile="$KH" -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -P "$PORT" \
	"$T/files/blob" "$U@127.0.0.1:up/blob" && cmp -s "$T/files/blob" "$T/home/up/blob" \
	&& scp -O -F /dev/null -o UserKnownHostsFile="$KH" -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -P "$PORT" \
	"$U@127.0.0.1:up/blob" "$T/files/blob.back" && cmp -s "$T/files/blob" "$T/files/blob.back" \
	&& ok "scp -O upload + download 1 MiB (builtin scp applet)" || bad "scp -O"
scp -F /dev/null -o UserKnownHostsFile="$KH" -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -i "$T/id1" -P "$PORT" \
	"$T/files/blob" "$U@127.0.0.1:up/blob2" >/dev/null 2>"$T/err" \
	&& ok "scp without -O also works with this client ($(ssh -V 2>&1 | cut -d, -f1); OpenSSH >= 9.0 defaults to sftp and needs -O)" \
	|| ok "scp WITHOUT -O fails as documented (no sftp-server): $(tr -d '\r' < "$T/err" | head -1)"
kill $HTTP 2>/dev/null; wait $HTTP 2>/dev/null
stop

# ---------------------------------------------- wildcard -p 2222 (spec literal)
env -i HOME="$T/home" "$QEMU" "$BIN" dropbear -R -F -E -p "$PORT" -r "$T/hostkey" -U "$U" -H "$H6" 2>>"$T/server.log" &
SRV=$!; sleep 2
ss -ltnH "sport = :$PORT" | grep -qE "(\*|0\.0\.0\.0|\[::\]):$PORT" && sshpw 'Six pass!' "$U" true \
	&& ok "-p $PORT (wildcard listen) + login" || bad "wildcard -p $PORT"
stop

# ------------------------------------------------- hardening (review round)
neg() { # expected-message description server-args...
	local msg="$1" desc="$2"; shift 2
	timeout 30 env -i HOME="$T/home" "$QEMU" "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" -r "$T/hostkey" "$@" > "$T/neg" 2>&1
	grep -q -- "$msg" "$T/neg" && ok "$desc" || bad "$desc: $(tail -2 "$T/neg")"
}
# crypt("", "$6$Mxempty") from glibc (openssl passwd can't hash an empty password;
# Python >= 3.13 has no crypt module)
HE='$6$Mxempty$Uqjy7H3VrHSbx93nzYWxUxAo2ppiaekT23608AZZOIhQfeKcskxYip5K8xVBQ0gAWKwrHUloeWOa4fOgRXZz3.'
neg "hash of an empty password" "-H hash of the empty password refused at startup" -U "$U" -H "$HE"
neg "Bad -k public key" "-k line with options (command=...) refused at startup" -U "$U" -k "command=\"true\" $(cat "$T/id1.pub")"
neg "Bad -k public key" "-k with a key type not built in (ssh-rsa) refused at startup" -U "$U" -k "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ x"
neg "Bad -U user name" "-U with shell metacharacters refused" -U 'a;b' -H "$H6"
neg "Bad -U user name" "-U starting with '-' refused" -U '-oops' -H "$H6"
grep -q "Login '$U' runs as uid $(id -u) gid $(id -g), home $T/home" "$T/server.log" \
	&& ok "startup log names login, uid/gid and home" || bad "no startup identity log line"
# -K: parent directory writable by group -> refused; file in sticky /tmp -> accepted
mkdir -p "$T/gw"; chmod 775 "$T/gw"; cat "$T/id1.pub" > "$T/gw/ak"; chmod 600 "$T/gw/ak"
STK="/tmp/dbmx-ak.$$"; cat "$T/id2.pub" > "$STK"; chmod 600 "$STK"
start HOME="$T/home" -- -r "$T/hostkey" -U "$U" -K "$T/gw/ak" -K "$STK" || exit 1
sshkey "$T/id1" "$U" true 2>/dev/null && bad "-K in group-writable directory accepted" || ok "-K file in a group-writable directory refused"
sshkey "$T/id2" "$U" true && ok "-K file directly in sticky /tmp accepted" || bad "-K in sticky /tmp refused"
stop; rm -f "$STK"
# daemon mode (no -F) with relative -r / -x / -K: resolved against the start
# directory, not against / (daemon() chdirs to /)
cat "$T/id1.pub" > "$T/home/relak"; chmod 600 "$T/home/relak"
( cd "$T/home" && env -i HOME="$T/home" "$QEMU" "$BIN" dropbear -R -E -p "127.0.0.1:$PORT" -r relkey -x rel.pid -U "$U" -K relak ) 2>>"$T/server.log"
for _ in $(seq 60); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.2; done
ssh -F /dev/null -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -p "$PORT" -o BatchMode=yes \
	-o IdentitiesOnly=yes -i "$T/id1" "$U@127.0.0.1" true </dev/null \
	&& [ -s "$T/home/relkey" ] && [ -s "$T/home/rel.pid" ] \
	&& ok "daemon mode: relative -r/-x/-K resolved against the start directory" \
	|| bad "daemon relative paths: $(ls -l "$T/home" 2>&1 | tr '\n' ' ')"
[ -s "$T/home/rel.pid" ] && kill "$(cat "$T/home/rel.pid")" 2>/dev/null; sleep 1

# -------------- -R with the key ABSENT at startup, long -r paths (UAF regression)
# Pre-fix, -R generated the key from the -r string that load_all_hostkeys()
# had already freed: connections failed or got different keys, and key files
# named after client data appeared in the server's cwd. Each round: fresh key
# path, server started in an empty cwd, 4 concurrent + 8 sequential
# connections (logins and ssh-keyscan); all must see one key, the key file's.
LONGD=$(printf 'long-directory-name-%02d/' 1 2 3 4 5 6 7 8)
# Clients come from different source addresses (127.0.0.2, ::1, 127.0.0.3,
# 127.0.0.1), so the per-connection address strings the server allocates
# differ in length; the server also listens on [::1] for that.
REP6=()
if [ -z "${NO_IPV6:-}" ] && python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1",0))' 2>/dev/null; then
	REP6=(-p "[::1]:$PORT"); export REP_SRCS="127.0.0.2 ::1 127.0.0.3 127.0.0.1"
else
	export REP_SRCS="127.0.0.2 127.0.0.3 127.0.0.1"
fi
# the short path from the report, when nobody else uses /tmp/x
REPX=""; [ -e /tmp/x ] || { mkdir -m 755 /tmp/x && REPX=/tmp/x; }
rep_round() { # label order -r-argument key-path-on-disk [path as the server logs it]
	local label="$1" order="$2" rarg="$3" kp="$4" lp="${5:-$4}" cwd="$T/repcwd" s n nd ne fp kfp lst alive
	rm -rf "$cwd" "$T/rk"; mkdir -p "$cwd" "$(dirname "$kp")"; rm -f "$kp"
	: > "$T/rep.log"
	( cd "$cwd" && exec env -i PATH=/usr/bin:/bin HOME="$T/home" "$QEMU" "$BIN" dropbear -R -F -E \
		-p "127.0.0.1:$PORT" "${REP6[@]}" -r "$rarg" -U "$U" -k "$(cat "$T/id1.pub")" ) 2>>"$T/rep.log" &
	SRV=$!
	for _ in $(seq 60); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.2; done
	[ -e "$kp" ] && bad "$label: key existed before the first connection"
	rep_conns "$order" "$PORT" "$U" "$T/id1" "$T/rk"
	s=$(rep_summary "$T/rk"); read -r n nd ne fp <<<"$s"
	kfp=$("$QEMU" "$BIN" dropbearkey -y -f "$kp" 2>/dev/null | grep '^ssh-ed25519 ' | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
	lst=$(cd "$(dirname "$kp")" && ls -A)
	kill -0 "$SRV" 2>/dev/null && alive=yes || alive=no
	stop
	cat "$T/rep.log" >> "$T/server.log"
	[ "$n" = 12 ] && [ "$nd" = 1 ] && [ "$ne" = 0 ] && [ -n "$kfp" ] && [ "$fp" = "$kfp" ] \
		&& ok "$label: 12 connections ($order), one host key = the -r file's ($fp)" \
		|| bad "$label: connections=$n distinct=$nd errors=$ne first=$fp keyfile=$kfp: $(sort "$T/rk/fps" | uniq -c | tr '\n' ' ' | cut -c1-300)"
	[ -z "$(ls -A "$cwd")" ] && [ "$lst" = "$(basename "$kp")" ] && [ "$(stat -c %a "$kp" 2>/dev/null)" = 600 ] && [ $alive = yes ] \
		&& ok "$label: server cwd still empty, key dir holds only the 0600 key, server alive" \
		|| bad "$label: cwd=[$(ls -A "$cwd" | tr '\n' ' ')] keydir=[$(echo "$lst" | tr '\n' ' ')] alive=$alive"
	! grep -qE "Failed moving key file|Couldn't read or generate hostkey" "$T/rep.log" \
		&& [ "$(grep -c "Generated hostkey" "$T/rep.log")" -ge 1 ] \
		&& [ "$(grep "Generated hostkey" "$T/rep.log" | grep -vFc "Generated hostkey $lp, fingerprint is")" = 0 ] \
		&& ok "$label: log names only $(echo "$lp" | sed "s#^$T#\$T#" | cut -c1-60)… ($(grep -c "Generated hostkey" "$T/rep.log")x Generated, no failures)" \
		|| bad "$label: server log: $(grep -E "hostkey|key file" "$T/rep.log" | sort | uniq -c | sed 's/^ *//' | cut -c1-200 | head -5 | tr '\n' '|')"
	local a miss=""
	for a in $REP_SRCS; do grep -q "Child connection from $a:" "$T/rep.log" || grep -q "Child connection from \[$a\]:" "$T/rep.log" || miss="$miss $a"; done
	[ -z "$miss" ] && ok "$label: server saw clients from $(echo $REP_SRCS | tr ' ' ',') ($(sort "$T/rk/srcs" | uniq -c | awk '{printf "%s %s/%s ", $1, $2, $3}'))" \
		|| bad "$label: no connection logged from:$miss ($(grep -o "Child connection from [^ ]*" "$T/rep.log" | sort | uniq -c | tr '\n' ' ' | cut -c1-200))"
}
[ -n "$REPX" ] && rep_round "-R regression /tmp/x/rep/ssh_host_ed25519" seq-first /tmp/x/rep/ssh_host_ed25519 /tmp/x/rep/ssh_host_ed25519
rep_round "-R regression /x/rep/ssh_host_ed25519" conc-first "$T/x/rep/ssh_host_ed25519" "$T/x/rep/ssh_host_ed25519"
rep_round "-R regression 230-char path" seq-first "$T/x/rep/${LONGD}ssh_host_ed25519_key" "$T/x/rep/${LONGD}ssh_host_ed25519_key"
rep_round "-R regression relative -r path" conc-first "../relkeys/${LONGD}ssh_host_ed25519" "$T/relkeys/${LONGD}ssh_host_ed25519" \
	"$T/repcwd/../relkeys/${LONGD}ssh_host_ed25519"

# ------------------------------------------------------------- server log hygiene
grep -q "Six pass\|Five pass\|pl ain" "$T/server.log" && bad "password appears in server log" || ok "no password text in server log"
echo "== server log sample:"; grep -E "Bad password|auth succeeded|Max auth|Login attempt for nonexistent" "$T/server.log" | sort -u -k3 | head -8 | sed 's/^/  /'
echo "== RESULT: $PASS passed, $FAIL failed"
printf '%s\n' "${RES[@]}" > "${MATRIX_OUT:-/dev/null}"
[ $FAIL -eq 0 ]
