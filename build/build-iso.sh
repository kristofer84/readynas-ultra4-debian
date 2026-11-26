#!/bin/sh
# Build the headless rescue ISO from an upstream grml release.
#
# Takes the release named in GRML_VERSION, verifies it against the hash pinned in
# upstream.sha256, swaps in the four files under rescue/, and rebuilds the image
# with the El Torito and partition-table options the 2011 BIOS needs.
#
# Usage:
#   build/build-iso.sh                     # fetch upstream, build into dist/
#   GRML_ISO=/path/to/grml.iso build/build-iso.sh   # build from a local copy
#
# Environment:
#   GRML_VERSION    grml release, default 2026.09 (the one that was verified)
#   GRML_VARIANT    full (default); small is untested on this hardware
#   SSH_PASSWORD    password for root and the grml user in the live system,
#                   default changeme - see docs/rescue-stick.md
#   RESCUE_HOSTNAME hostname on the live system, default grmlnas
#   GRML_PEER       address grml.sh pings so the box can be found by ARP;
#                   unset means no ping
#   GRML_ISO        use this file instead of downloading
#   SOURCE_DATE_EPOCH  timestamp written to every file and to the volume header,
#                   default 1788436673 (2026-09-03, the grml 2026.09 release).
#                   This is what makes two builds byte-identical.
#   XORRISO_PIN     require this xorriso version, so a build that cannot match a
#                   published sha256 fails instead of quietly differing
#   OUT             output directory, default dist
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")

GRML_VERSION=${GRML_VERSION:-2026.09}
GRML_VARIANT=${GRML_VARIANT:-full}
ARCH=amd64
SSH_PASSWORD=${SSH_PASSWORD:-changeme}
RESCUE_HOSTNAME=${RESCUE_HOSTNAME:-grmlnas}
GRML_PEER=${GRML_PEER:-}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1788436673}
export SOURCE_DATE_EPOCH
OUT=${OUT:-dist}
WORK=${WORK:-build/work}

UPSTREAM_NAME="grml-${GRML_VARIANT}-${GRML_VERSION}-${ARCH}.iso"
UPSTREAM_URL="https://download.grml.org/${UPSTREAM_NAME}"
OUT_NAME="readynas-rescue-${GRML_VERSION}-${ARCH}.iso"

# Substitutions must not break the kernel command line or the ISO contents.
case "$SSH_PASSWORD$RESCUE_HOSTNAME$GRML_PEER" in
    *[!A-Za-z0-9._-]*) echo "build-iso: password, hostname and peer must be [A-Za-z0-9._-]" >&2; exit 2 ;;
esac

# The toolchain decides the bytes as much as the inputs do: refuse to build with
# a different xorriso when the caller pinned one.
XORRISO_PIN=${XORRISO_PIN:-}
XORRISO_VER=$(xorriso -version 2>/dev/null | head -1 | sed 's/.*xorriso \([0-9][0-9.]*\).*/\1/')
if [ -n "$XORRISO_PIN" ] && [ "$XORRISO_VER" != "$XORRISO_PIN" ]; then
    echo "build-iso: xorriso $XORRISO_VER, XORRISO_PIN asks for $XORRISO_PIN" >&2
    echo "build-iso: the sha256 would not match a build made with $XORRISO_PIN" >&2
    exit 3
fi

mkdir -p "$OUT" "$WORK"

# --- 1. the upstream image, pinned -------------------------------------------
if [ -n "${GRML_ISO:-}" ]; then
    ISO=$GRML_ISO
else
    ISO="$WORK/$UPSTREAM_NAME"
    WANT=$(awk -v n="$UPSTREAM_NAME" '$2 == n {print $1}' "$HERE/upstream.sha256")
    [ -n "$WANT" ] || { echo "build-iso: $UPSTREAM_NAME is not in upstream.sha256" >&2; exit 2; }
    if [ -f "$ISO" ] && [ "$(sha256sum "$ISO" | cut -d' ' -f1)" = "$WANT" ]; then
        echo "build-iso: using cached $ISO"
    else
        rm -f "$ISO"
        echo "build-iso: fetching $UPSTREAM_URL"
        curl -fL --retry 3 --retry-delay 5 -o "$ISO.part" "$UPSTREAM_URL"
        mv "$ISO.part" "$ISO"
    fi
    GOT=$(sha256sum "$ISO" | cut -d' ' -f1)
    [ "$GOT" = "$WANT" ] || {
        echo "build-iso: upstream sha256 mismatch" >&2
        echo "  want $WANT" >&2
        echo "  got  $GOT" >&2
        exit 1
    }
    echo "build-iso: upstream sha256 matches upstream.sha256"
fi

# --- 2. unpack and patch ------------------------------------------------------
TREE="$WORK/tree"
rm -rf "$TREE"
mkdir -p "$TREE"
xorriso -osirrox on -indev "$ISO" -extract / "$TREE" >/dev/null 2>&1
chmod -R u+w "$TREE"

for f in grub_local_custom_early.cfg grub_local_custom_pre_entry.cfg grub_local_custom_late.cfg; do
    src="$REPO/rescue/$f"
    dst="$TREE/boot/grub/$f"
    cp "$src" "$dst"
    sed -i "s/ssh=CHANGEME/ssh=$SSH_PASSWORD/; s/hostname=grmlnas/hostname=$RESCUE_HOSTNAME/" "$dst"
done

# Upstream grml has no /scripts: grml-autoconfig runs whatever it finds in
# $dcsdir/scripts (the live medium root) when the `scripts` boot option is set.
mkdir -p "$TREE/scripts"
cp "$REPO/rescue/grml.sh" "$TREE/scripts/grml.sh"
chmod 0755 "$TREE/scripts/grml.sh"
sed -i "s/^PEER=.*/PEER=$GRML_PEER/" "$TREE/scripts/grml.sh"

grep -q "ssh=$SSH_PASSWORD" "$TREE/boot/grub/grub_local_custom_early.cfg" || {
    echo "build-iso: password did not land in the boot config" >&2; exit 1; }

# --- 3. fixed timestamps ------------------------------------------------------
# The ISO records mtime, atime and ctime per file. Extraction restores the
# upstream mtimes for most files but not for the four that were rewritten, and
# ctime cannot be set with touch at all, so pin every one of them to
# SOURCE_DATE_EPOCH and have xorriso copy mtime into atime and ctime
# (--set_all_file_dates set_to_mtime). With SOURCE_DATE_EPOCH exported,
# xorrisofs also takes it as the default modification date.
find "$TREE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
MODDATE=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y%m%d%H%M%S)00

# --- 4. rebuild ---------------------------------------------------------------
# The El Torito options are what the working image reports. The partition_* flags
# are what the 2011 BIOS needs: grml ships GRUB's MBR code but an all-zero
# partition table, and a partitionless disk may not be offered as bootable.
# GRUB finds its core image by embedded LBA and ignores the table, so filling
# bytes 446-509 cannot disturb it.
echo "build-iso: rebuilding"
# -as mkisofs, not native xorriso: the El Torito and partition options below are
# the mkisofs emulation's spelling of them, and the recorded image reports
# exactly these (xorriso -report_el_torito as_mkisofs). iso_mbr_part_type has no
# mkisofs equivalent and is patched in afterwards, see below.
xorriso -as mkisofs \
    -V "READYNAS_RESCUE_${GRML_VERSION}" \
    --grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt:"$ISO" \
    --protective-msdos-label \
    -partition_cyl_align on -partition_offset 0 --mbr-force-bootable \
    --modification-date="$MODDATE" \
    -r \
    --set_all_file_dates set_to_mtime \
    -c /boot.catalog \
    -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table \
    --grub2-boot-info \
    -eltorito-alt-boot \
    -e /boot/efi.img -no-emul-boot -boot-load-size 8192 \
    -o "$OUT/$OUT_NAME" "$TREE"

# --- 5. MBR partition type ----------------------------------------------------
# The recorded run set iso_mbr_part_type=0x00, the layout Debian's own ISOs use:
# partition 1 active and spanning the image, type 0. xorriso's mkisofs emulation
# writes 0xcd instead, so patch the one byte. verify-iso.sh checks it.
printf '\000' | dd of="$OUT/$OUT_NAME" bs=1 seek=450 count=1 conv=notrunc status=none

# --- 6. checksums, build record, and a size that will not fit on a CD ------------------------
( cd "$OUT" && sha256sum "$OUT_NAME" > SHA256SUMS && ls -l "$OUT_NAME" )

# What a rebuild has to match to produce the same hash.
{
    echo "image:            $OUT_NAME"
    echo "grml version:     $GRML_VERSION ($GRML_VARIANT, $ARCH)"
    echo "upstream sha256:  $(sha256sum "$ISO" | cut -d' ' -f1)"
    echo "source date:      $SOURCE_DATE_EPOCH ($(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ))"
    echo "xorriso:          $(xorriso -version 2>/dev/null | head -1 | tr -s ' ')"
    echo "build host:       $(uname -m), $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    echo "ssh password:     $([ "$SSH_PASSWORD" = changeme ] && echo 'changeme (default)' || echo 'custom, not recorded')"
} > "$OUT/BUILD-INFO.txt"
cat "$OUT/BUILD-INFO.txt"

echo "build-iso: wrote $OUT/$OUT_NAME"
echo "build-iso: this is grml $GRML_VERSION remastered. Redistributing the result"
echo "build-iso: is fine under the GPL; do not call it grml."
