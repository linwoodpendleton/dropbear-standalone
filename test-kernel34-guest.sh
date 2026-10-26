#!/bin/sh
# Guest side of test-kernel34.sh (runs as /data/test.sh under the
# Linux 3.4.113 initramfs, which has NO /etc/passwd, /etc/group, /etc/shadow).
# The servers run as uid/gid 1000:1000, which has no passwd entry.
# Files expected in /data: dropbearmulti h6 pw id1.pub id2.pub
cd /data
echo "M34: kernel $(uname -r) $(uname -m); /etc: $(ls /etc | tr '\n' ' ')"
ls /etc/passwd /etc/shadow /etc/group 2>&1 | sed 's/^/M34: /'

# --- negative /dev/urandom checks (root, before anything else; 3.4 has no getrandom)
./dropbearmulti dropbearkey -t ed25519 -f /tmp/k0 >/dev/null 2>&1 && echo "M34: dropbearkey(root) ok" || echo "M34: dropbearkey(root) FAILED"
: > /tmp/fakeurandom
mount --bind /tmp/fakeurandom /dev/urandom
timeout 10 ./dropbearmulti dropbearkey -t ed25519 -f /tmp/k1 > /tmp/neg1 2>&1; echo "M34: urandom=regular-file rc=$? msg=$(tail -1 /tmp/neg1)"
umount /dev/urandom
mount --bind /dev/null /dev/urandom
timeout 10 ./dropbearmulti dropbearkey -t ed25519 -f /tmp/k2 > /tmp/neg2 2>&1; echo "M34: urandom=/dev/null rc=$? msg=$(tail -1 /tmp/neg2)"
umount /dev/urandom
ls -l /dev/urandom | sed 's/^/M34: /'

# --- unprivileged user 1000 (no passwd entry)
mkdir -p /home/u /www
chown 1000:1000 /home/u; chmod 755 /home/u
dd if=/dev/urandom of=/www/blob bs=1024 count=1024 2>/dev/null
cat /data/id2.pub > /home/u/ak; chown 1000:1000 /home/u/ak; chmod 600 /home/u/ak
cp /data/h6 /data/pw /home/u/; chown 1000:1000 /home/u/h6 /home/u/pw; chmod 600 /home/u/h6 /home/u/pw
httpd -p 127.0.0.1:8080 -h /www

AS="chpst -u 1000:1000"
$AS id 2>&1 | sed "s/^/M34: chpst: /"

# --- privilege checks: a setuid/setgid copy must refuse to run for uid 1000;
#     root with -U naming a real (passwd) account of another uid must refuse
cp /data/dropbearmulti /data/suid; chown 0:0 /data/suid; chmod 4755 /data/suid
$AS /data/suid dropbearkey -y -f /tmp/k0 > /tmp/neg3 2>&1; echo "M34: setuid-root rc=$? msg=$(tail -1 /tmp/neg3)"
chmod 2755 /data/suid
$AS /data/suid dropbearkey -y -f /tmp/k0 > /tmp/neg4 2>&1; echo "M34: setgid-root rc=$? msg=$(tail -1 /tmp/neg4)"
rm -f /data/suid
echo 'alice:x:1000:1000::/home/u:/bin/sh' > /etc/passwd
timeout 20 ./dropbearmulti dropbear -F -E -p 2299 -r /tmp/k9 -U alice -P xyz > /tmp/neg5 2>&1; echo "M34: root -U alice(uid 1000) rc=$? msg=$(grep -m1 -- '-U alice' /tmp/neg5)"
rm -f /etc/passwd
E="env -i HOME=/home/u PATH=/bin:/sbin:/usr/bin:/usr/sbin"
K1="$(cat /data/id1.pub)"
# A: -H hash from file, restartable (-x pid file) for the host-key persistence test
$AS $E sh -c 'while :; do /data/dropbearmulti dropbear -R -F -E -p 2222 -r /home/u/hostkey -x /home/u/a.pid -U tester -H @/home/u/h6; echo "M34: server A exited rc=$?, restarting"; sleep 1; done' >/dev/console 2>&1 &
# B: -P @file + -k
$AS $E /data/dropbearmulti dropbear -R -F -E -p 2223 -r /home/u/hostkey -U tester -P @/home/u/pw -k "$K1" >/dev/console 2>&1 &
# C: -K file only
$AS $E /data/dropbearmulti dropbear -R -F -E -p 2224 -r /home/u/hostkey -U tester -K /home/u/ak >/dev/console 2>&1 &
# D: -P literal on the command line + DROPBEAR_PASSWORD in env (argv/environ wipe check), daemon mode (no -F) to check it backgrounds
$AS $E DROPBEAR_PASSWORD='Env Secret 34' /data/dropbearmulti dropbear -R -E -p 2225 -r /home/u/hostkey -U tester -P 'Literal Secret 34' >/dev/console 2>&1
# E: started as ROOT with a synthetic -U (no passwd entry), daemon mode, -H
#    literal (must be wiped from cmdline), relative -r/-x from cwd /home/u
#    (must not end up in / after daemon() chdir)
(cd /home/u && env -i PATH=/bin:/sbin:/usr/bin:/usr/sbin /data/dropbearmulti dropbear -R -E -p 2226 -r ekey -x e.pid -D /tmp -U admin -H "$(cat /data/h6)") >/dev/console 2>&1
# F, G: -R with the key ABSENT at startup and long -r paths (regression for the
#   use-after-free of the -r string), each started in its own empty cwd that
#   must stay empty (pre-fix, stray key files named after client data appeared)
LONGD=$(printf 'long-directory-name-%02d/' 1 2 3 4 5 6 7 8)
mkdir -p /home/u/fcwd /home/u/gcwd /tmp/x/rep /tmp/x/rep2/$LONGD
chown -R 1000:1000 /home/u/fcwd /home/u/gcwd /tmp/x; chmod 755 /tmp/x /tmp/x/rep /tmp/x/rep2
(cd /home/u/fcwd && exec $AS $E /data/dropbearmulti dropbear -R -F -E -p 2227 -r /tmp/x/rep/ssh_host_ed25519 -U tester -k "$K1") >/dev/console 2>&1 &
(cd /home/u/gcwd && exec $AS $E /data/dropbearmulti dropbear -R -F -E -p 2228 -r "/tmp/x/rep2/${LONGD}ssh_host_ed25519_key" -U tester -k "$K1") >/dev/console 2>&1 &
sleep 3
netstat -ltn 2>/dev/null | grep -E ':222[2-8] ' | sed 's/^/M34: /'
ps -o pid,user,args | grep '[d]ropbear' | sed 's/^/M34: /'
echo "M34-READY"
