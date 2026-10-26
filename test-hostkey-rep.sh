# Sourced by test-matrix-user.sh and test-kernel34.sh (bash).
#
# Regression helper for the -R use-after-free (fixed in this patch):
# upstream load_all_hostkeys() m_free()s every -r path at startup, and the
# pre-fix svr-kex.c generated the -R host key later from that freed string.
# With the key absent at startup, connections then failed ("Failed moving key
# file to : ...", "Couldn't read or generate hostkey") or the server wrote new
# key files into its working directory, named after whatever had reused the
# memory (client version string, client address, ...). It only shows with
# longer -r paths, e.g. /tmp/x/rep/ssh_host_ed25519.
#
# rep_conns ORDER PORT USER IDENTITY DIR
#   ORDER=conc-first: 4 concurrent connections, then 8 sequential
#   ORDER=seq-first : 8 sequential connections, then 4 concurrent
#   Connection kinds rotate: full key login (ssh ... 'echo REP-OK'),
#   ssh-keyscan (other client version string), and an unauthenticated
#   connection that is refused (unknown user; the host key is still seen).
#   Each writes the host key fingerprint it saw (or "ERR(...): ...") to
#   DIR/fp.<n>; DIR/fps gets all of them in connection order.
# rep_summary DIR
#   prints "<connections> <distinct fingerprints> <errors> <first fingerprint>"
# REP_HOST: server address (default 127.0.0.1)
# REP_SRCS: optional client SOURCE addresses to rotate through, so that the
#   server's per-connection address strings differ in length, e.g.
#   "127.0.0.2 ::1 127.0.0.3 127.0.0.1" (the server must then also listen on
#   [::1]). IPv4 sources are set with ssh -o BindAddress against REP_HOST;
#   ssh-keyscan cannot bind, so a scan from 127.0.0.2/3 becomes a refused ssh.
#   DIR/src.<n> records the source used.

REP_G=0

rep_one() { # n kind port user identity dir src
	local n=$1 kind=$2 p=$3 u=$4 id=$5 d=$6 src=${7:-} dst="${REP_HOST:-127.0.0.1}" bind=()
	local kh="$d/kh.$n"
	case "$src" in
		*:*) dst="::1";;
		"") ;;
		*) [ "$src" != "$dst" ] && bind=(-o BindAddress="$src");;
	esac
	[ "$kind" = scan ] && [ ${#bind[@]} -gt 0 ] && kind=deny
	echo "${src:-$dst} $kind" > "$d/src.$n"
	rm -f "$kh"
	if [ "$kind" = login ] || [ "$kind" = deny ]; then
		local lu="$u" want=REP-OK
		[ "$kind" = deny ] && { lu="nosuch$u"; want="Permission denied"; }
		ssh -F /dev/null -o UserKnownHostsFile="$kh" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
			-o ConnectTimeout=90 -o BatchMode=yes -o IdentitiesOnly=yes "${bind[@]}" -i "$id" -p "$p" "$lu@$dst" \
			'echo REP-OK' </dev/null >"$d/out.$n" 2>&1
		if grep -q "$want" "$d/out.$n" && [ -s "$kh" ]; then
			ssh-keygen -lf "$kh" | awk '{print $2}' > "$d/fp.$n"
		else
			echo "ERR($kind $src): $(tr '\n' ' ' < "$d/out.$n" | cut -c1-160)" > "$d/fp.$n"
		fi
	else
		ssh-keyscan -T 90 -t ed25519 -p "$p" "$dst" > "$kh" 2>"$d/out.$n"
		if [ -s "$kh" ]; then
			ssh-keygen -lf "$kh" | awk '{print $2}' > "$d/fp.$n"
		else
			echo "ERR(keyscan $src): $(tr '\n' ' ' < "$d/out.$n" | cut -c1-160)" > "$d/fp.$n"
		fi
	fi
}

rep_next() { # sets KIND and SRC for the next connection
	local srcs=(${REP_SRCS:-})
	case $((REP_G % 3)) in 0) KIND=login;; 1) KIND=scan;; *) KIND=deny;; esac
	SRC=""
	[ ${#srcs[@]} -gt 0 ] && SRC=${srcs[$((REP_G % ${#srcs[@]}))]}
	REP_G=$((REP_G + 1))
}

rep_conns() { # order port user identity dir
	local order=$1 p=$2 u=$3 id=$4 d=$5 i pids names=() KIND SRC
	rm -rf "$d"; mkdir -p "$d"
	REP_G=0
	_rep_conc() {
		pids=()
		for i in 1 2 3 4; do
			rep_next
			rep_one "c$i" $KIND "$p" "$u" "$id" "$d" "$SRC" &
			pids+=($!)
		done
		wait "${pids[@]}"   # only these: the caller's server is a job too
		names+=(c1 c2 c3 c4)
	}
	_rep_seq() {
		for i in 1 2 3 4 5 6 7 8; do
			rep_next
			rep_one "s$i" $KIND "$p" "$u" "$id" "$d" "$SRC"
			names+=("s$i")
		done
	}
	if [ "$order" = conc-first ]; then _rep_conc; _rep_seq; else _rep_seq; _rep_conc; fi
	for i in "${names[@]}"; do cat "$d/fp.$i"; done > "$d/fps"
	for i in "${names[@]}"; do cat "$d/src.$i"; done > "$d/srcs"
}

rep_summary() { # dir
	local f="$1/fps"
	echo "$(wc -l < "$f") $(grep -v '^ERR' "$f" | sort -u | wc -l) $(grep -c '^ERR' "$f") $(grep -v '^ERR' "$f" | head -1)"
}
