#!/usr/bin/env bash
# Reproducible build of a single static Dropbear multi-call binary for
# ARMv7 Cortex-A7 (hard-float, NEON-VFPv4, Thumb-2), musl, Linux >= 3.4.
#
# Runs on an x86_64 Linux host. Needs: bash, curl, tar, bzip2, make, gpg
# (optional), sha256sum/sha512sum, python3 not required.
#
# Usage:
#   ./build.sh                 # default deliverable: dropbear + dropbearkey + scp
#   ./build.sh --variants      # also build the size-comparison variants
#   ./build.sh --only "name dropbear,scp -DEMB_LOCALFWD=0"   # one custom build
#   ./build.sh --client        # second release asset: + dbclient (ssh client)
#   ./build.sh --asan          # test-only x86_64 ASan/UBSan build of the same
#                              # patched tree -> $WORK/asan/ (see below)
#   WORK=/some/dir ./build.sh  # where downloads/toolchain/build trees go
#
# Output: ./out/dropbearmulti (+ ./out/variants/* with --variants,
#         ./out/variants/dropbearmulti-client with --client or --variants)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HOME/build-dropbear-armv7}"
OUT="$HERE/out"

DB_VER=2026.94
DB_TARBALL="dropbear-$DB_VER.tar.bz2"
DB_URL="https://matt.ucc.asn.au/dropbear/releases/$DB_TARBALL"
DB_SHA256=e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81
# Dropbear release signing key (releases/dropbear-key-2015.asc)
DB_GPG_FPR=F7347EF2EE2E07A267628CA944931494F29C6773

TC_NAME=armv7l-linux-musleabihf-cross
TC_URL="https://musl.cc/$TC_NAME.tgz"
# from https://musl.cc/SHA512SUMS (gcc 11.2.1, musl 1.2.2)
TC_SHA512=1bb399a61da425faac521df9b8d303e60ad101f6c7827469e0b4bc685ce1f3dedc606ac7b1e8e34d79f762a3bfe3e8ab479a97e97d9f36fbd9fc5dc9d7ed6fd1
HOST=armv7l-linux-musleabihf

# musl is rebuilt from source: Thumb-2 + -Os (the prebuilt libc.a is ARM
# mode, ~30% larger) and current security fixes (the prebuilt is 1.2.2).
MUSL_VER=1.2.6
MUSL_URL="https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz"
MUSL_SHA256=d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a
MUSL_GPG_FPR=836489290BB6B70F99FFDA0556BCDB593020450F
# security patches announced on musl.libc.org for "all releases through 1.2.6"
MUSL_PATCHES="
2026/04/10/3/1 1ee29f64f9ca8e8ad7c349779d661ff6b52126a27575d3586981357a52c406fb CVE-2026-40200-qsort
2026/04/03/2/1 444fa70e52ca158fb7d4bad560637790bbf8f72e80b82fff840dd66fa83091e3 CVE-2026-6042-iconv
2026/10/21/1/1 0cf0090ab433e8f9ed08ae03a0c93aff557c1d3e347260f62a61a10281f5333b CVE-2026-107891-regcomp
"

# Reproducibility: fixed timestamps, fixed locale, fixed paths in the build
export SOURCE_DATE_EPOCH=1784800000
export LC_ALL=C TZ=UTC
umask 022

JOBS="${JOBS:-$(nproc)}"
NICE=(nice -n 15)
command -v ionice >/dev/null && NICE=(ionice -c3 nice -n 15)

mkdir -p "$WORK/dl-dropbear" "$WORK/dl-toolchain" "$OUT"

# ---------------------------------------------------------------- sources
fetch() { # url dest
	[ -s "$2" ] || { curl -sSfL --retry 3 -m 900 -o "$2.part" "$1" && mv "$2.part" "$2"; }
}
fetch "$DB_URL" "$WORK/dl-dropbear/$DB_TARBALL"
echo "$DB_SHA256  $WORK/dl-dropbear/$DB_TARBALL" | sha256sum -c -
if command -v gpg >/dev/null; then
	fetch "$DB_URL.asc" "$WORK/dl-dropbear/$DB_TARBALL.asc"
	fetch "https://matt.ucc.asn.au/dropbear/releases/dropbear-key-2015.asc" "$WORK/dl-dropbear/dropbear-key-2015.asc"
	G="$WORK/gnupg"; mkdir -p "$G"; chmod 700 "$G"
	GNUPGHOME="$G" gpg --batch -q --import "$WORK/dl-dropbear/dropbear-key-2015.asc" 2>/dev/null || true
	GNUPGHOME="$G" gpg --batch --status-fd 1 --verify "$WORK/dl-dropbear/$DB_TARBALL.asc" \
		"$WORK/dl-dropbear/$DB_TARBALL" 2>/dev/null | grep -q "VALIDSIG $DB_GPG_FPR" \
		|| { echo "GPG signature check FAILED" >&2; exit 1; }
	echo "gpg: good signature from $DB_GPG_FPR"
fi

# ---------------------------------------------------------------- --asan
# Test-only build of the SAME patched tree for the build host (x86_64 glibc,
# dynamic, -fsanitize=address,undefined), to run the qemu user-mode test
# suites natively under AddressSanitizer (QEMU=env ./test-*.sh <binary>).
# Not a deliverable and not reproducible; nothing from it goes into out/.
# Reports go to stderr and to /tmp/dbasan/{asan,ubsan}.<pid> (mkdir -m 1777).
if [ "${1:-}" = "--asan" ]; then
	asan_build() { # name programs extra-cflags
		local name="$1" progs="$2" cf="$3" B="$WORK/build/asan-$1"
		case " $progs " in *" dbclient "*) cf="$cf -DEMB_NO_DNS=0 -DEMB_CLIENT=1";; *) cf="$cf -DEMB_SCP_SERVER_ONLY";; esac
		rm -rf "$B"; mkdir -p "$B"
		tar -xjf "$WORK/dl-dropbear/$DB_TARBALL" -C "$B" --strip-components=1
		( cd "$B" && patch -p1 -s < "$HERE/dropbear-$DB_VER-embedded.patch" )
		cp "$HERE/localoptions.h" "$B/localoptions.h"
		cat > "$B/asan_defaults.c" <<'EOF'
/* the test scripts start the server with "env -i": bake the options in */
const char *__asan_default_options(void) {
	return "detect_leaks=0:halt_on_error=1:abort_on_error=0:log_path=/tmp/dbasan/asan:log_exe_name=1";
}
const char *__ubsan_default_options(void) {
	return "print_stacktrace=1:halt_on_error=0:log_path=/tmp/dbasan/ubsan:log_exe_name=1";
}
EOF
		local SAN="-fsanitize=address,undefined -fno-sanitize=alignment -fno-omit-frame-pointer"
		(
			cd "$B"
			gcc -c -O1 -o asan_defaults.o asan_defaults.c
			"${NICE[@]}" ./configure -q --disable-harden --disable-zlib --disable-shadow --disable-pam \
				--enable-bundled-libtom --disable-syslog --disable-lastlog --disable-utmp --disable-utmpx \
				--disable-wtmp --disable-wtmpx --disable-loginfunc --disable-pututline --disable-pututxline \
				CC=gcc CFLAGS="-O1 -g $SAN $cf" LDFLAGS="$SAN $B/asan_defaults.o" LTM_CFLAGS="-O1 -g $SAN" >/dev/null
			"${NICE[@]}" make -s -j"$JOBS" MULTI=1 PROGRAMS="$progs" SCPPROGRESS=0 >/dev/null
		)
		mkdir -p "$WORK/asan"
		install -m 0755 "$B/dropbearmulti" "$WORK/asan/dropbearmulti-$name"
		echo "asan: $WORK/asan/dropbearmulti-$name  [$progs]"
	}
	asan_build default "dropbear dropbearkey scp" ""
	asan_build client "dropbear dropbearkey scp dbclient" ""
	exit 0
fi

fetch "$TC_URL" "$WORK/dl-toolchain/$TC_NAME.tgz"
echo "$TC_SHA512  $WORK/dl-toolchain/$TC_NAME.tgz" | sha512sum -c -
if [ ! -x "$WORK/toolchain/$TC_NAME/bin/$HOST-gcc" ]; then
	mkdir -p "$WORK/toolchain"
	tar -xzf "$WORK/dl-toolchain/$TC_NAME.tgz" -C "$WORK/toolchain"
fi

# ---------------------------------------------------------------- musl
ARCH_FLAGS="-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -mthumb"
mkdir -p "$WORK/dl-musl"
fetch "$MUSL_URL" "$WORK/dl-musl/musl-$MUSL_VER.tar.gz"
echo "$MUSL_SHA256  $WORK/dl-musl/musl-$MUSL_VER.tar.gz" | sha256sum -c -
if command -v gpg >/dev/null; then
	fetch "$MUSL_URL.asc" "$WORK/dl-musl/musl-$MUSL_VER.tar.gz.asc"
	fetch "https://musl.libc.org/musl.pub" "$WORK/dl-musl/musl.pub"
	GNUPGHOME="$WORK/gnupg" gpg --batch -q --import "$WORK/dl-musl/musl.pub" 2>/dev/null || true
	GNUPGHOME="$WORK/gnupg" gpg --batch --status-fd 1 --verify "$WORK/dl-musl/musl-$MUSL_VER.tar.gz.asc" \
		"$WORK/dl-musl/musl-$MUSL_VER.tar.gz" 2>/dev/null | grep -q "VALIDSIG $MUSL_GPG_FPR" \
		|| { echo "musl GPG signature check FAILED" >&2; exit 1; }
	echo "gpg: good musl signature from $MUSL_GPG_FPR"
fi
echo "$MUSL_PATCHES" | while read -r path sum name; do
	[ -n "$path" ] || continue
	fetch "https://www.openwall.com/lists/musl/$path" "$WORK/dl-musl/$name.patch"
	echo "$sum  $WORK/dl-musl/$name.patch" | sha256sum -c -
done

# Toolchain copy whose sysroot gets the freshly built musl
TCM="$WORK/toolchain-musl$MUSL_VER"
if [ ! -f "$TCM/.musl-$MUSL_VER-done" ]; then
	rm -rf "$WORK/musl-src" "$WORK/musl-inst" "$TCM"
	mkdir -p "$WORK/musl-src"
	tar -xzf "$WORK/dl-musl/musl-$MUSL_VER.tar.gz" -C "$WORK/musl-src" --strip-components=1
	echo "$MUSL_PATCHES" | while read -r path sum name; do
		[ -n "$path" ] || continue
		( cd "$WORK/musl-src" && patch -p1 -s < "$WORK/dl-musl/$name.patch" )
	done
	(
		cd "$WORK/musl-src"
		export PATH="$WORK/toolchain/$TC_NAME/bin:$PATH"
		"${NICE[@]}" ./configure --target=$HOST --prefix=/ --disable-shared \
			CROSS_COMPILE=$HOST- CC=$HOST-gcc \
			CFLAGS="-Os $ARCH_FLAGS -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables -fno-unwind-tables -ffile-prefix-map=$WORK=/build" >/dev/null
		"${NICE[@]}" make -s -j"$JOBS" >/dev/null
		make -s install DESTDIR="$WORK/musl-inst" >/dev/null
	)
	cp -al "$WORK/toolchain/$TC_NAME" "$TCM"
	SR="$TCM/$HOST"
	# replace (not modify in place: files are hardlinks) libc + headers
	for f in "$WORK"/musl-inst/lib/*; do rm -f "$SR/lib/$(basename "$f")"; cp -a "$f" "$SR/lib/"; done
	rm -f "$SR/lib/libc.so" "$SR/lib/ld-musl-armhf.so.1"
	( cd "$WORK/musl-inst/include" && find . -type f ) | while read -r h; do
		rm -f "$SR/include/$h"; mkdir -p "$(dirname "$SR/include/$h")"; cp -a "$WORK/musl-inst/include/$h" "$SR/include/$h"
	done
	touch "$TCM/.musl-$MUSL_VER-done"
fi
TC="$TCM/bin"
export PATH="$TC:$PATH"

# ---------------------------------------------------------------- flags
BASE_CFLAGS="-Os $ARCH_FLAGS -ffunction-sections -fdata-sections \
-fno-asynchronous-unwind-tables -fno-unwind-tables -fomit-frame-pointer \
-fno-ident -fno-pie -ffile-prefix-map=$WORK=/build"
# arch/opt flags are repeated at link time so that -flto code generation matches
BASE_LDFLAGS="-Os $ARCH_FLAGS -static -no-pie -Wl,--gc-sections -Wl,-O1 -Wl,--build-id=none -Wl,-z,norelro -Wl,--hash-style=gnu"

# build <name> <programs> <extra flags: -D.. / -f.. go to CFLAGS, --.. to configure>
build() {
	local name="$1" progs="$2" extra="$3" cf="" conf=""
	local x
	for x in $extra; do
		case "$x" in --*) conf="$conf $x";; *) cf="$cf $x";; esac
	done
	# scp without an ssh client can only be the remote end (-t/-f)
	case " $progs " in *" dbclient "*) ;; *) cf="$cf -DEMB_SCP_SERVER_ONLY";; esac
	# the client needs real host name resolution, and gets -L/-R forwarding
	case " $progs " in *" dbclient "*) cf="$cf -DEMB_NO_DNS=0 -DEMB_CLIENT=1";; esac
	local B="$WORK/build/$name"
	rm -rf "$B"; mkdir -p "$B"
	tar -xjf "$WORK/dl-dropbear/$DB_TARBALL" -C "$B" --strip-components=1
	( cd "$B" && patch -p1 -s < "$HERE/dropbear-$DB_VER-embedded.patch" )
	cp "$HERE/localoptions.h" "$B/localoptions.h"
	(
		cd "$B"
		"${NICE[@]}" ./configure -q --host=$HOST --enable-static --disable-harden \
			--disable-zlib --disable-shadow --disable-pam --enable-bundled-libtom \
			--disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
			--disable-loginfunc --disable-pututline --disable-pututxline $conf \
			ac_cv_func_getgrouplist=no \
			CC="$HOST-gcc" AR="$HOST-gcc-ar" RANLIB="$HOST-gcc-ranlib" \
			CFLAGS="$BASE_CFLAGS $cf" LDFLAGS="$BASE_LDFLAGS $cf" LTM_CFLAGS="-Os" >/dev/null
		"${NICE[@]}" make -s -j"$JOBS" AR="$HOST-gcc-ar" RANLIB="$HOST-gcc-ranlib" MULTI=1 STATIC=1 PROGRAMS="$progs" SCPPROGRESS=0 >/dev/null
		"$HOST-strip" --strip-all -R .comment -o dropbearmulti.stripped dropbearmulti
	)
	echo "$name: $(stat -c %s "$B/dropbearmulti.stripped") bytes (text+data $("$HOST-size" "$B/dropbearmulti.stripped" | awk 'NR==2{print $1"+"$2}'))  [$progs] $extra"
}

DEFAULT_PROGS="dropbear dropbearkey scp"
# no syslog by default: logs go to stderr (-E is accepted and implied).
# syslog() drags in localtime/strftime/timezone code (+5.5 kB).
DEFAULT_EXTRA="--disable-syslog"

if [ "${1:-}" = "--only" ]; then
	# ./build.sh --only "name prog1,prog2 [-DEMB_x=1 --configure-opt ...]"
	read -r name progs extra <<<"$2"
	build "$name" "${progs//,/ }" "$extra"
	exit 0
fi

CLIENT_PROGS="dropbear dropbearkey scp dbclient"
client_asset() {
	install -m 0755 "$WORK/build/default+dbclient/dropbearmulti.stripped" "$OUT/variants/dropbearmulti-client"
	( cd "$OUT/variants" && sha256sum dropbearmulti-client > dropbearmulti-client.sha256 && cat dropbearmulti-client.sha256 )
}

if [ "${1:-}" = "--client" ]; then
	mkdir -p "$OUT/variants"
	build default+dbclient "$CLIENT_PROGS" "$DEFAULT_EXTRA"
	client_asset
	exit 0
fi

if [ "${1:-}" = "--variants" ]; then
	mkdir -p "$OUT/variants"
	while read -r name progs extra; do
		[ -n "$name" ] || continue
		build "$name" "${progs//,/ }" "$extra"
		cp "$WORK/build/$name/dropbearmulti.stripped" "$OUT/variants/dropbear-$name"
	done <<EOF
server-only dropbear $DEFAULT_EXTRA
server+key dropbear,dropbearkey $DEFAULT_EXTRA
default dropbear,dropbearkey,scp $DEFAULT_EXTRA
default-noLfwd dropbear,dropbearkey,scp $DEFAULT_EXTRA -DEMB_LOCALFWD=0
default+aesctr dropbear,dropbearkey,scp $DEFAULT_EXTRA -DEMB_AESCTR=1
default+pqkex dropbear,dropbearkey,scp $DEFAULT_EXTRA -DEMB_PQ_KEX=1
default+inetd dropbear,dropbearkey,scp $DEFAULT_EXTRA -DEMB_INETD=1
default+dns dropbear,dropbearkey,scp $DEFAULT_EXTRA -DEMB_NO_DNS=0
default+syslog dropbear,dropbearkey,scp
default+ssp dropbear,dropbearkey,scp $DEFAULT_EXTRA -fstack-protector-strong
default+dbclient dropbear,dropbearkey,scp,dbclient $DEFAULT_EXTRA
default+dbclient+convert dropbear,dropbearkey,scp,dbclient,dropbearconvert $DEFAULT_EXTRA
EOF
	( cd "$OUT/variants" && ls -l | awk 'NR>1{print $5, $9}' && sha256sum dropbear-* > SHA256SUMS )
	client_asset
fi

build default "$DEFAULT_PROGS" "$DEFAULT_EXTRA"
install -m 0755 "$WORK/build/default/dropbearmulti.stripped" "$OUT/dropbearmulti"
( cd "$OUT" && sha256sum dropbearmulti > dropbearmulti.sha256 && cat dropbearmulti.sha256 )
