/*
 * localoptions.h for the single-file embedded Dropbear build
 * (ARMv7 Cortex-A7, static musl, single-user mode).
 *
 * Knobs (pass with CFLAGS=-DEMB_xxx=0/1, see build.sh):
 *   EMB_LOCALFWD  1  ssh -L local port forwarding (server side)
 *   EMB_AESCTR    0  aes128-ctr + hmac-sha2-256 in addition to chacha20-poly1305
 *   EMB_PQ_KEX    0  mlkem768x25519-sha256 post-quantum hybrid KEX
 *   EMB_INETD     0  "-i" inetd mode
 *   EMB_NO_DNS    1  numeric addresses only (+ "localhost"): no libc DNS
 *                    resolver, no /etc/hosts, /etc/resolv.conf, /etc/services
 *   EMB_CLIENT    0  set by build.sh when dbclient is built: client -L/-R
 */
#ifndef EMB_LOCALFWD
#define EMB_LOCALFWD 1
#endif
#ifndef EMB_AESCTR
#define EMB_AESCTR 0
#endif
#ifndef EMB_PQ_KEX
#define EMB_PQ_KEX 0
#endif
#ifndef EMB_INETD
#define EMB_INETD 0
#endif
#ifndef EMB_NO_DNS
#define EMB_NO_DNS 1
#endif
#ifndef EMB_CLIENT
#define EMB_CLIENT 0
#endif

/* ---- process model ---- */
#define NON_INETD_MODE 1
#define INETD_MODE EMB_INETD
/* re-exec per connection needs fexecve (execveat 3.19+ or /proc) */
#define DROPBEAR_REEXEC 0
#define DROPBEAR_SMALL_CODE 1
#define DEBUG_TRACE 0

/* ---- forwarding ---- */
#define DROPBEAR_X11FWD 0
#define DROPBEAR_SVR_AGENTFWD 0
#define DROPBEAR_CLI_AGENTFWD 0
#define DROPBEAR_SVR_LOCALTCPFWD EMB_LOCALFWD
#define DROPBEAR_SVR_REMOTETCPFWD 0
#define DROPBEAR_SVR_LOCALSTREAMFWD 0
#define DROPBEAR_SVR_REMOTESTREAMFWD 0
#define DROPBEAR_CLI_LOCALTCPFWD EMB_CLIENT
#define DROPBEAR_CLI_REMOTETCPFWD EMB_CLIENT
#define DROPBEAR_CLI_PROXYCMD 0
#define DROPBEAR_CLI_NETCAT 0

/* ---- algorithms: curve25519 / ed25519 / chacha20-poly1305 ---- */
#define DROPBEAR_USER_ALGO_LIST 0
#define DROPBEAR_CHACHA20POLY1305 1
#define DROPBEAR_AES128 EMB_AESCTR
#define DROPBEAR_AES256 0
#define DROPBEAR_3DES 0
#define DROPBEAR_ENABLE_CTR_MODE EMB_AESCTR
#define DROPBEAR_ENABLE_CBC_MODE 0
#define DROPBEAR_ENABLE_GCM_MODE 0
/* chacha20-poly1305 is an AEAD and needs no separate MAC */
#define DROPBEAR_SHA1_HMAC 0
#define DROPBEAR_SHA2_256_HMAC EMB_AESCTR
#define DROPBEAR_SHA2_512_HMAC 0
#define DROPBEAR_SHA1_96_HMAC 0

#define DROPBEAR_RSA 0
#define DROPBEAR_RSA_SHA1 0
#define DROPBEAR_DSS 0
#define DROPBEAR_ECDSA 0
#define DROPBEAR_ED25519 1
#define DROPBEAR_SK_KEYS 0
#define DROPBEAR_DELAY_HOSTKEY 1

#define DROPBEAR_DH_GROUP1 0
#define DROPBEAR_DH_GROUP1_CLIENTONLY 0
#define DROPBEAR_DH_GROUP14_SHA1 0
#define DROPBEAR_DH_GROUP14_SHA256 0
#define DROPBEAR_DH_GROUP16 0
#define DROPBEAR_CURVE25519 1
#define DROPBEAR_ECDH 0
#define DROPBEAR_SNTRUP761 0
#define DROPBEAR_MLKEM768 EMB_PQ_KEX

/* ---- server behaviour ---- */
#define DO_MOTD 0
#define DO_HOST_LOOKUP 0
#define DROPBEAR_SVR_PASSWORD_AUTH 1
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 1
/* authorized_keys options (command=, from=...) compiled out; lines that
   carry options are refused (fail closed, see svr-authpubkey.c) */
#define DROPBEAR_SVR_PUBKEY_OPTIONS 0
/* sessions always run as the server's own uid; root can still log in
   as root when the server runs as root */
#define DROPBEAR_SVR_MULTIUSER 1
#define DROPBEAR_SFTPSERVER 0
#define LOG_COMMANDS 0

/* ---- client (only matters for the +dbclient variant) ---- */
#define DROPBEAR_CLI_PASSWORD_AUTH 1
#define DROPBEAR_CLI_PUBKEY_AUTH 1
#define DROPBEAR_USE_PASSWORD_ENV 0
#define DROPBEAR_CLI_ASKPASS_HELPER 0
#define DROPBEAR_USE_SSH_CONFIG 0

/* ---- paths ---- */
#define DROPBEAR_PATH_SSH_PROGRAM "dbclient"
#define DEFAULT_PATH "/usr/bin:/bin:/usr/sbin:/sbin"
#define DEFAULT_ROOT_PATH "/usr/sbin:/usr/bin:/sbin:/bin"
