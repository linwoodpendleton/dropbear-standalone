#!/bin/sh
/data/fma
cat /etc/resolv.conf
( while true; do echo "NK34-NC-OK $(uname -r)" | nc -l -p 22; done ) >/dev/null 2>&1 &
echo SMOKE-READY
