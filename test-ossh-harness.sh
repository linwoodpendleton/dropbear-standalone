# Sourced by test-client.sh and test-client-kernel34.sh (bash).
#
# start_ossh DIR PORT PASSWORD AUTHORIZED_KEYS_FILE
#   Starts the host's own OpenSSH sshd (/usr/sbin/sshd) WITHOUT root: inside a
#   rootless user+mount namespace (podman unshare) with a throw-away user
#   "pwuser" (uid 2000 in the namespace) whose password and authorized_keys are
#   given here. Fake /etc/passwd and /etc/shadow, the privsep directory and a
#   private devpts instance are bind-mounted only inside that mount namespace.
#   Listens on 127.0.0.1:PORT (reachable from qemu user-net guests as 10.0.2.2).
#   Home directory (writable, for scp): DIR/home/pwuser.  Log: DIR/sshd.log.
# stop_ossh DIR
#
# NSRUN: how to enter a user namespace where we are root. Default
# "podman unshare" (rootless); when the tests themselves already run as root
# (e.g. on the board) NSRUN=env is enough.
NSRUN=${NSRUN:-podman unshare}
if [ "$(id -u)" = 0 ] && [ "$NSRUN" = "podman unshare" ] && ! command -v podman >/dev/null; then
	NSRUN=env
fi
start_ossh() {
	local O="$1" PORT="$2" PW="$3" AK="$4" H6
	mkdir -p "$O/etc" "$O/run-sshd" "$O/home/pwuser/.ssh"
	cp /etc/passwd /etc/group "$O/etc/"
	echo "pwuser:x:2000:2000:pw user:$O/home/pwuser:/bin/sh" >> "$O/etc/passwd"
	# (openssl, not python3 crypt: Python >= 3.13 has no crypt module)
	H6=$(openssl passwd -6 "$PW")
	printf 'root:*:19000:0:99999:7:::\nsshd:*:19000:0:99999:7:::\npwuser:%s:19000:0:99999:7:::\n' "$H6" > "$O/etc/shadow"
	cp "$AK" "$O/home/pwuser/.ssh/authorized_keys"
	ssh-keygen -q -t ed25519 -N '' -f "$O/hk"
	cat > "$O/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $O/hk
PidFile $O/sshd.pid
UsePAM no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile $O/home/pwuser/.ssh/authorized_keys
StrictModes no
AllowTcpForwarding yes
PermitRootLogin no
AllowUsers pwuser
MaxAuthTries 6
LogLevel VERBOSE
EOF
	# OpenSSH >= 9.8 penalises (blocks) source addresses that fail auth or
	# drop connections, which the negative tests do on purpose. Probe the
	# option instead of comparing version numbers.
	if ! /usr/sbin/sshd -t -f /dev/null -o PerSourcePenalties=no -o HostKey="$O/hk" 2>&1 \
			| grep -qi "bad configuration option"; then
		echo "PerSourcePenalties no" >> "$O/sshd_config"
	fi
	$NSRUN unshare -m bash -c "
		set -e
		chown -R 2000:2000 $O/home/pwuser; chown 0:0 $O/run-sshd; chmod 755 $O/run-sshd; chmod 640 $O/etc/shadow
		mount --bind $O/etc/passwd /etc/passwd
		mount --bind $O/etc/shadow /etc/shadow
		mount --bind $O/run-sshd /run/sshd
		# own devpts instance: the host's tty group is not mapped in this namespace
		mount -t devpts -o newinstance,ptmxmode=0666,mode=0620,gid=5 devpts /dev/pts
		mount --bind /dev/pts/ptmx /dev/ptmx
		/usr/sbin/sshd -E $O/sshd.log -f $O/sshd_config
	" || return 1
	for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && return 0; sleep 0.2; done
	return 1
}

stop_ossh() {
	[ -s "$1/sshd.pid" ] && kill "$(cat "$1/sshd.pid")" 2>/dev/null
	return 0
}
