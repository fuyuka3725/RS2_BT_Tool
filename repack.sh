#!/usr/bin/env bash
# HiBy RS2: rebuild firmware with the BT-mode files from the BT-mod.
#
# Run inside WSL/Linux, in a folder on the *Linux* filesystem (e.g. ~/rs2), NOT under /mnt/c.
# Needed in this folder: rs2_origin.upt  bt_overlay.tar  manifest.tsv  check_tree.py  repack.sh
#
#   sudo apt install mtd-utils genisoimage p7zip-full python3-pip
#   sudo pip3 install --break-system-packages ubi_reader      # (or: pip3 install ubi_reader)
#   sudo env "PATH=$PATH" ./repack.sh [rs2_origin.upt]
#
# Result: out/rs2.upt and out/rs2.md5sum
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
UPT=${1:-$HERE/rs2.upt}
OVERLAY=$HERE/bt_overlay.tar
MANIFEST=$HERE/manifest.tsv
CHECK=$HERE/check_tree.py
WORK=$HERE/work
OUT=$HERE/out
# UBIFS geometry read from the original images (min I/O 2048, LEB 124 KiB, 480 LEBs, LZO)
MIN_IO=2048; LEB=126976; MAX_LEB=480

say()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo env \"PATH=\$PATH\" ./repack.sh"
case "$HERE" in /mnt/*) die "this folder is on the Windows drive ($HERE). Copy everything to ~/rs2 inside WSL first - NTFS breaks permissions/symlinks." ;; esac
for f in "$UPT" "$OVERLAY" "$MANIFEST" "$CHECK"; do [ -f "$f" ] || die "missing file: $f"; done
for c in mkfs.ubifs genisoimage python3 md5sum ubireader_extract_files; do command -v "$c" >/dev/null || die "missing tool: $c (see header of this script)"; done
if command -v 7z >/dev/null; then EXTRACT=7z; elif command -v bsdtar >/dev/null; then EXTRACT=bsdtar; else die "need 7z (p7zip-full) or bsdtar"; fi

unpack_upt() {   # $1 = upt  $2 = dest
  mkdir -p "$2"
  if [ "$EXTRACT" = 7z ]; then 7z x -y -o"$2" "$1" >/dev/null; else bsdtar -xf "$1" -C "$2"; fi
}
find_ci() { find "$1" -maxdepth 1 -iname "$2*" | head -n1; }
find_root() {    # locate the directory that holds bin/ etc/ usr/
  local d
  while IFS= read -r d; do
    p=$(dirname "$d"); [ -d "$p/bin" ] && [ -d "$p/usr" ] && { echo "$p"; return; }
  done < <(find "$1" -maxdepth 5 -type d -name etc)
  return 1
}

rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"

say "1/7 unpack $UPT"
unpack_upt "$UPT" "$WORK/upt"
SYSTEM=$(find_ci "$WORK/upt" system.ubi); UBOOT=$(find_ci "$WORK/upt" uboot.bin); KERNEL=$(find_ci "$WORK/upt" uimage.bin)
UPDATE=$(find_ci "$WORK/upt" update.txt);  VERSION=$(find_ci "$WORK/upt" version.txt)
for v in SYSTEM UBOOT KERNEL UPDATE VERSION; do [ -n "${!v}" ] || die "$v not found inside the upt"; done
want=$(awk '/system\.ubi/{f=1} f&&/md5=/{sub(/.*md5=/,"");print;exit}' "$UPDATE" | tr -d '\r')
have=$(md5sum "$SYSTEM" | cut -d' ' -f1)
[ "$want" = "$have" ] || die "input SYSTEM.UBI md5 ($have) does not match UPDATE.TXT ($want) - corrupt input?"
echo "input rootfs md5 OK: $have"

say "2/7 extract rootfs (ubi_reader, keeping owner/permissions)"
ubireader_extract_files -k -o "$WORK/ubifs" "$SYSTEM" >/dev/null
ROOT=$(find_root "$WORK/ubifs") || die "could not locate extracted rootfs under $WORK/ubifs"
echo "rootfs dir: $ROOT"

say "3/7 verify extraction against manifest (mode/owner/size/symlinks)"
python3 "$CHECK" manifest "$ROOT" "$MANIFEST" || die "extraction does not match the 1.4 manifest - NOT continuing (a bad rootfs can brick the player)"

say "4/7 apply BT overlay"
tar --numeric-owner -xpf "$OVERLAY" -C "$ROOT"
python3 "$CHECK" overlay "$ROOT" "$OVERLAY" || die "overlay not applied correctly"

say "5/7 build UBIFS image"
mkfs.ubifs -r "$ROOT" -m $MIN_IO -e $LEB -c $MAX_LEB -x lzo -o "$OUT/system.ubi"
sz=$(stat -c %s "$OUT/system.ubi"); max=$((LEB*MAX_LEB))
[ "$sz" -le "$max" ] || die "image ($sz bytes) exceeds partition ($max bytes)"
echo "system.ubi: $sz bytes (limit $max)"

say "6/7 verify the new image with an independent read-back"
ubireader_extract_files -k -o "$WORK/verify" "$OUT/system.ubi" >/dev/null
VROOT=$(find_root "$WORK/verify") || die "cannot read back new image"
python3 "$CHECK" overlay "$VROOT" "$OVERLAY" || die "read-back of new image failed"

say "7/7 assemble upt"
STAGE="$WORK/stage"; mkdir -p "$STAGE"
cp "$UBOOT" "$STAGE/uboot.bin"; cp "$KERNEL" "$STAGE/uimage.bin"; cp "$VERSION" "$STAGE/version.txt"
cp "$OUT/system.ubi" "$STAGE/system.ubi"
printf '*.*\n' > "$STAGE/.gitignore"                 # same 4-byte file as the original
newmd5=$(md5sum "$STAGE/system.ubi" | cut -d' ' -f1)
python3 - "$UPDATE" "$STAGE/update.txt" "$newmd5" <<'PY'
import re,sys
src,dst,md5=sys.argv[1:4]
t=open(src,'rb').read().decode()
t2,n=re.subn(r'(file_path=autoupdate/system\.ubi\s*\r?\n\s*md5=)[0-9a-fA-F]{32}', r'\g<1>'+md5, t)
assert n==1,'rootfs md5 line not found in UPDATE.TXT'
open(dst,'wb').write(t2.encode())
PY
genisoimage -quiet -iso-level 1 -V CDROM -sysid LINUX -o "$OUT/rs2.upt" "$STAGE"
( cd "$OUT" && md5sum rs2.upt > rs2.md5sum )

# final check: unpack the new upt and compare the rootfs md5 with UPDATE.TXT
unpack_upt "$OUT/rs2.upt" "$WORK/final"
f_sys=$(find_ci "$WORK/final" system.ubi); f_upd=$(find_ci "$WORK/final" update.txt)
fm=$(awk '/system\.ubi/{f=1} f&&/md5=/{sub(/.*md5=/,"");print;exit}' "$f_upd" | tr -d '\r')
[ "$(md5sum "$f_sys" | cut -d' ' -f1)" = "$fm" ] || die "final upt self-check failed"
cmp -s "$UBOOT" "$(find_ci "$WORK/final" uboot.bin)" && cmp -s "$KERNEL" "$(find_ci "$WORK/final" uimage.bin)" || die "uboot/kernel changed unexpectedly"

say "DONE"
ls -l "$OUT/rs2.upt" "$OUT/rs2.md5sum"; cat "$OUT/rs2.md5sum"
echo "uboot/kernel are byte-identical to the original 1.4 package; only rootfs (system.ubi) changed."
