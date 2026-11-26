#!/bin/sh
# Put the new kernel on the internal boot module and point syslinux at it.
# Run from the rescue system, with the new root mounted (chroot-configure.sh
# already done).
#
#   boot-module.sh --root /mnt/target
#
# What it does not do: reinstall syslinux. LDLINUX.SYS is the 2013 binary, found
# by the boot sector at a fixed location; FAT does not relocate existing files,
# so replacing the config and the two payload files is the change with the least
# that can go wrong.
#
# What it refuses to do: guess the module device. It must find exactly one FAT
# partition between 100 and 200 MB, and it prints the size and the device before
# writing.
#
# NOT yet executed on a ReadyNAS. The commands are the ones recorded in
# docs/install.md, which were run by hand on 2026-09-08.
set -eu

ROOT=/mnt/target
MODULE=""
FAIL=0
MNT=/run/dom-sync

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=1; }
die()  { printf 'FAIL  %s\n' "$*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --root)    ROOT=${2:?}; shift 2 ;;
        --module)  MODULE=${2:?}; shift 2 ;;
        -h|--help) usage ;;
        *)         printf 'unknown argument: %s\n' "$1" >&2; usage ;;
    esac
done

[ -f "$ROOT/etc/fstab" ] || die "$ROOT does not look like the new root (no /etc/fstab)"

# --- 1. the root UUID, from the fstab that will be used ----------------------
ROOTUUID=$(awk '$2 == "/" {print $1}' "$ROOT/etc/fstab" | sed 's/^UUID=//')
[ -n "$ROOTUUID" ] || die "no UUID= root line in $ROOT/etc/fstab"
blkid -U "$ROOTUUID" >/dev/null 2>&1 || die "root UUID $ROOTUUID is on no device here"
ok "root UUID $ROOTUUID"

# --- 2. kernel and initrd ----------------------------------------------------
KERNEL=$(ls -1 "$ROOT"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls -1 "$ROOT"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
[ -n "$KERNEL" ] || die "no vmlinuz in $ROOT/boot"
[ -n "$INITRD" ] || die "no initrd in $ROOT/boot"
ok "kernel $(basename "$KERNEL"), initrd $(basename "$INITRD")"

# --- 3. the module -----------------------------------------------------------
if [ -z "$MODULE" ]; then
    COUNT=0
    for d in $(blkid -t TYPE=vfat -o device 2>/dev/null); do
        case "$(lsblk -no MOUNTPOINT "$d" 2>/dev/null | tr -d ' ')" in
            /run/live*) continue ;;
        esac
        size=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
        if [ "$size" -ge 100000000 ] && [ "$size" -le 200000000 ]; then
            MODULE=$d; COUNT=$((COUNT + 1))
        fi
    done
    [ "$COUNT" -eq 1 ] || die "expected exactly one 100-200 MB vfat device, found $COUNT"
fi
MODSIZE=$(blockdev --getsize64 "$MODULE")
ok "module $MODULE, $MODSIZE bytes"
case "$MODSIZE" in
    125304832) ;;
    *) warn "not the 125 304 832 bytes recorded for the Ultra 4: confirm this is the module" ;;
esac

# --- 4. room for a working pair plus a fallback ------------------------------
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$MODULE" "$MNT"
need=$(( ( $(stat -c %s "$KERNEL") + $(stat -c %s "$INITRD") ) * 2 ))
have=$(( $(df --output=avail -B1 "$MNT" | tail -1) \
        + $(stat -c %s "$MNT/VMLINUZ" 2>/dev/null || echo 0) \
        + $(stat -c %s "$MNT/INITRD.IMG" 2>/dev/null || echo 0) ))
if [ "$have" -lt "$need" ]; then
    umount "$MNT"
    die "$have bytes usable, need $need for two kernels"
fi
ok "$have bytes usable, $need needed for two kernels"

# --- 5. keep the outgoing pair, then write -----------------------------------
same=no
if [ -f "$MNT/VMLINUZ" ] && cmp -s "$KERNEL" "$MNT/VMLINUZ"; then same=yes; fi
if [ "$same" = no ] && [ -f "$MNT/VMLINUZ" ]; then
    cp -f "$MNT/VMLINUZ" "$MNT/VMLINUZ.OLD"
    cp -f "$MNT/INITRD.IMG" "$MNT/INITRD.OLD"
    sync
    ok "kept the outgoing pair as VMLINUZ.OLD / INITRD.OLD"
fi
cp -f "$KERNEL" "$MNT/VMLINUZ.NEW"
cp -f "$INITRD" "$MNT/INITRD.NEW"
sync
mv -f "$MNT/VMLINUZ.NEW" "$MNT/VMLINUZ"
mv -f "$MNT/INITRD.NEW" "$MNT/INITRD.IMG"
sync

cat > "$MNT/SYSLINUX.CFG" <<EOF
serial 0 9600
default debian
prompt 0
timeout 30

label debian
  kernel VMLINUZ
  append initrd=INITRD.IMG root=UUID=$ROOTUUID ro rootfstype=ext4 console=tty0 console=ttyS0,115200n8

label memtest
  kernel MEMTEST
EOF
sync
ok "SYSLINUX.CFG written (prompt 0, timeout 30, rootfstype=ext4)"

# --- 6. gates ----------------------------------------------------------------
grep -q "root=UUID=$ROOTUUID" "$MNT/SYSLINUX.CFG" || bad "the root UUID did not land in SYSLINUX.CFG"
[ "$(stat -c %s "$MNT/VMLINUZ")" = "$(stat -c %s "$KERNEL")" ] || bad "VMLINUZ is not the kernel that was copied"
[ "$(stat -c %s "$MNT/INITRD.IMG")" = "$(stat -c %s "$INITRD")" ] || bad "INITRD.IMG is not the initrd that was copied"

# Anything else on the module that is still bootable is a hazard: the ReadyNASOS
# initrd says "No partitions found on any disk! Going to factory default..." and
# md0 no longer holds ReadyNASOS. Names differ between units, so list them and
# stop rather than guess.
OTHERS=$(ls -1 "$MNT" | grep -viE '^(LDLINUX\.SYS|SYSLINUX\.CFG|VMLINUZ|VMLINUZ\.OLD|INITRD\.IMG|INITRD\.OLD|MEMTEST|VERSION\.TXT|vpd|\.)$' || true)
if [ -n "$OTHERS" ]; then
    warn "other files on the module, check each for a bootable ReadyNASOS pair:"
    echo "$OTHERS" | sed 's/^/        /'
    warn "delete any leftover kernel/initrd pair by hand; do not leave one bootable"
fi
ok "module contents:"
ls -l "$MNT" | sed 's/^/        /'
umount "$MNT"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "Ready to boot. Power off, then hold the front Backup button while watching it"
    echo "come up: the first boot needs a fix (wait-online) that is easier with the button"
    echo "within reach. See docs/gotchas.md."
else
    echo "Do not boot this module yet: see FAIL above." >&2
    exit 1
fi
