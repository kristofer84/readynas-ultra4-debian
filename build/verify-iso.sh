#!/bin/sh
# Structural checks on a built rescue ISO. Cannot prove it boots; it proves the
# three things that silently went wrong on the way to a working image:
#   - a partition table the 2011 BIOS will accept
#   - the GRUB MBR code still in place, with boot signature
#   - the four remastered files present, with the password actually substituted
#
# Usage: build/verify-iso.sh dist/readynas-rescue-2026.09-amd64.iso [password]
set -eu

ISO=${1:?usage: verify-iso.sh <iso> [password]}
PASSWORD=${2:-changeme}
FAIL=0

say() { printf '%s %s\n' "$1" "$2"; }
ok()  { say ok    "$1"; }
bad() { say FAIL  "$1"; FAIL=1; }

[ -s "$ISO" ] || { bad "no such file: $ISO"; exit 1; }

SIZE=$(stat -c %s "$ISO")
[ "$SIZE" -gt 1000000000 ] && ok "size $SIZE" || bad "size $SIZE, expected over 1 GB"

# MBR: boot signature, one active partition, partition type 0x00 (what the
# remaster sets), and a protective-msdos-label rather than an all-zero table.
python3 - "$ISO" <<'PY' || FAIL=1
import struct, sys
f = open(sys.argv[1], "rb")
mbr = f.read(512)
def ok(m): print("ok   ", m)
def bad(m):
    print("FAIL ", m); raise SystemExit(1)
if mbr[510:512] != b"\x55\xaa":
    bad("no 0x55aa boot signature at 510")
part = mbr[446:462]
if part == b"\0" * 16:
    bad("partition table is empty - the BIOS may not offer the disk")
if not part[0] & 0x80:
    bad("partition 1 has no active/boot flag")
if part[4] != 0x00:
    bad("partition type is 0x%02x, expected 0x00 (the recorded layout)" % part[4])
ok("MBR: boot signature, one active partition, type 0x00")
PY

# GRUB MBR code plus the El Torito entries we expect to have written.
TORITO=$(xorriso -indev "$ISO" -report_el_torito as_mkisofs 2>/dev/null)
case "$TORITO" in
    *--grub2-mbr*) ok "El Torito: grub2-mbr" ;;
    *) bad "El Torito: no grub2-mbr" ;;
esac
case "$TORITO" in
    *eltorito.img*) ok "El Torito: BIOS entry at /boot/grub/i386-pc/eltorito.img" ;;
    *) bad "El Torito: no BIOS boot entry" ;;
esac
case "$TORITO" in
    *boot/efi.img*) ok "El Torito: UEFI entry present" ;;
    *) bad "El Torito: no UEFI entry" ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
xorriso -osirrox on -indev "$ISO" \
    -extract /scripts/grml.sh "$TMP/grml.sh" \
    -extract /boot/grub/grub_local_custom_early.cfg "$TMP/early.cfg" \
    -extract /boot/grub/grub_local_custom_pre_entry.cfg "$TMP/pre.cfg" \
    -extract /boot/grub/grub_local_custom_late.cfg "$TMP/late.cfg" >/dev/null 2>&1 \
    || { bad "the four remastered files are not all in the image"; exit 1; }

for f in grml.sh early.cfg pre.cfg late.cfg; do
    [ -s "$TMP/$f" ] && ok "present: $f" || bad "empty or missing: $f"
done

grep -q "ssh=$PASSWORD" "$TMP/early.cfg" && ok "password substituted in early.cfg" \
    || bad "early.cfg does not carry ssh=$PASSWORD"
grep -q 'serial --unit=0' "$TMP/pre.cfg" && ok "serial menu mirroring in place" \
    || bad "pre_entry.cfg is not the serial one"
grep -q 'PEER=' "$TMP/grml.sh" && ok "grml.sh carries a PEER line" \
    || bad "grml.sh has no PEER line"

[ "$FAIL" -eq 0 ] || { echo "verify-iso: FAILED" >&2; exit 1; }
echo "verify-iso: structure ok. This does not prove it boots: do that with the"
echo "verify-iso: Backup button on the machine, once, while you can still rebuild."
