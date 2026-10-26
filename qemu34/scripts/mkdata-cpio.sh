#!/bin/bash
# Pack files into /data/ as a gzip'd newc cpio, to be APPENDED to a base initramfs.
#   usage: mkdata-cpio.sh <out.cpio.gz> <file>...   (one of the files should be test.sh)
# Needs only cpio + gzip on the host (no root: owner is forced to 0:0).
set -euo pipefail
OUT=$(realpath -m "$1"); shift
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data"
for f in "$@"; do cp "$f" "$T/data/"; done
chmod 0755 "$T/data"/*
( cd "$T" && find data | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) | gzip -9n > "$OUT"
echo "wrote $OUT"
