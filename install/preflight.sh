#!/bin/sh
# Pre-flight for a ReadyNASOS -> Debian conversion. Run from the rescue system,
# before anything is written to the machine.
#
# It proves the arrays assemble and the data reads, then takes the three things
# that cannot be recovered afterwards: an image of the internal boot module, a
# tar of the ReadyNASOS root, and the per-share settings from the data array.
#
#   preflight.sh --data /dev/md127 --hash-file /mnt/preflight-raid/other/big.bin
#   preflight.sh --data /dev/md127 --hash-file ... --skip-root-tar --out /root/pf
#   preflight.sh --data /dev/md127 --hash-file auto   # pick a large file yourself
#   preflight.sh --data /dev/md127 --no-data         # array is meant to be empty
#
# Exit 0 means go: from here the only thing that may be reformatted is md0.
# Nothing in this script writes to the NAS. It reads, and it writes to --out.
#
# NOT yet executed on a ReadyNAS. The commands are the ones recorded in
# docs/install.md, which were run by hand on 2026-09-08.
set -eu

DATA=""
HASH_FILE=""
OUT="/root/preflight"
SKIP_ROOT_TAR=no
NODATA=no
RAID_MNT=/mnt/preflight-raid
ROOT_MNT=/mnt/preflight-root
FAIL=0

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=1; }
die()  { printf 'FAIL  %s\n' "$*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --data)          DATA=${2:?}; shift 2 ;;
        --hash-file)     HASH_FILE=${2:?}; shift 2 ;;
        --out)           OUT=${2:?}; shift 2 ;;
        --skip-root-tar) SKIP_ROOT_TAR=yes; shift ;;
        --no-data)       NODATA=yes; shift ;;
        -h|--help)       usage ;;
        *)               printf 'unknown argument: %s\n' "$1" >&2; usage ;;
    esac
done
[ -n "$DATA" ] || usage
[ -n "$HASH_FILE" ] || [ "$NODATA" = yes ] || usage
command -v btrfs >/dev/null || die "btrfs-progs is not installed in this live system"

mkdir -p "$OUT"
echo "preflight: data=$DATA out=$OUT"

# --- 1. every array is complete ---------------------------------------------
[ -r /proc/mdstat ] || die "no /proc/mdstat: is md loaded?"
if awk '/^md[0-9]+/ && /_/' /proc/mdstat | grep -q .; then
    awk '/^md[0-9]+/ {print}' /proc/mdstat
    die "an array is degraded (there is a _ in /proc/mdstat)"
fi
ok "no degraded array in /proc/mdstat"

# --- 2. the data array is the kind of array mdadm will assemble --------------
[ -b "$DATA" ] || die "$DATA is not a block device"
DETAIL=$(mdadm --detail "$DATA")
echo "$DETAIL" | grep -q 'Version : 1.2' || bad "md metadata is not 1.2: $(echo "$DETAIL" | grep Version)"
echo "$DETAIL" | grep -qE 'Raid Level : raid[0-9]+' || bad "cannot read the raid level"
LEVEL=$(echo "$DETAIL" | awk -F': ' '/Raid Level/ {print $2}')
DEVICES=$(echo "$DETAIL" | awk -F': ' '/Raid Devices/ {print $2}')
ok "metadata 1.2, $LEVEL, $DEVICES devices"
printf '%s %s %s\n' "$DATA" "$LEVEL" "$DEVICES devices" > "$OUT/data-device.txt"

# --- 3. the filesystem is one a current kernel mounts ------------------------
FSTYPE=$(blkid -s TYPE -o value "$DATA" 2>/dev/null || true)
case "$FSTYPE" in
    btrfs|ext4|xfs) ok "filesystem $FSTYPE" ;;
    "") bad "no filesystem signature on $DATA" ;;
    *)  warn "filesystem $FSTYPE: this procedure was recorded on btrfs" ;;
esac

# --- 4. it mounts read-only, the counters are zero, and a file reads back ----
MOUNTED=no
if [ -z "$FSTYPE" ]; then
    if [ "$NODATA" = yes ]; then
        warn "no filesystem signature on $DATA and --no-data given: nothing to mount, nothing to prove"
    else
        die "no filesystem signature on $DATA. If the array is meant to be empty, re-run with --no-data"
    fi
else
    mkdir -p "$RAID_MNT"
    mountpoint -q "$RAID_MNT" || mount -o ro "$DATA" "$RAID_MNT"
    MOUNTED=yes

    if [ "$FSTYPE" = btrfs ]; then
        STATS=$(btrfs device stats "$RAID_MNT")
        if echo "$STATS" | awk '{print $NF}' | grep -qv '^0$'; then
            echo "$STATS"
            bad "btrfs device stats are not all zero"
        else
            ok "btrfs device stats: every counter zero"
        fi
        SUBVOLS=$(btrfs subvolume list "$RAID_MNT" | wc -l)
        ok "btrfs subvolumes: $SUBVOLS"
    fi

    if [ "$HASH_FILE" = auto ]; then
        # Largest regular file over 100 MB, so nobody has to browse the array to
        # find something worth hashing.
        HASH_FILE=$(find "$RAID_MNT" -xdev -type f -size +100M -printf '%s %p\n' 2>/dev/null \
                    | sort -n | tail -1 | cut -d' ' -f2-)
        if [ -n "$HASH_FILE" ]; then
            ok "largest file over 100 MB: $(printf '%s' "$HASH_FILE" | sed "s|^$RAID_MNT||")"
        else
            die "no file over 100 MB on $DATA. If the array is empty, re-run with --no-data"
        fi
    fi

    if [ -n "$HASH_FILE" ]; then
        [ -f "$HASH_FILE" ] || die "$HASH_FILE is not a regular file inside the mount"
        SIZE=$(stat -c %s "$HASH_FILE")
        SUM=$(sha256sum "$HASH_FILE" | cut -d' ' -f1)
        ok "sha256 of $(printf '%s' "$HASH_FILE" | sed "s|^$RAID_MNT||") ($SIZE bytes): $SUM"
        printf '%s  %s\n' "$SUM" "$HASH_FILE" > "$OUT/data-proof.sha256"
    elif [ "$NODATA" = yes ]; then
        warn "no --hash-file: no read proof taken, because there is said to be nothing on it"
    else
        die "--hash-file is required. If the array is meant to be empty, re-run with --no-data"
    fi
fi

# --- 5. the boot module ------------------------------------------------------
# Under the rescue system it is a plain block device: a single FAT16 partition
# between 100 and 200 MB. It is NEVER addressed as /dev/sdX afterwards.
MODULE=""
CANDIDATES=0
for d in $(blkid -t TYPE=vfat -o device 2>/dev/null); do
    case "$(lsblk -no MOUNTPOINT "$d" 2>/dev/null | tr -d ' ')" in
        /run/live*) continue ;;
    esac
    size=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
    if [ "$size" -ge 100000000 ] && [ "$size" -le 200000000 ]; then
        MODULE=$d; CANDIDATES=$((CANDIDATES + 1))
        ok "boot module candidate: $d ($size bytes)"
    fi
done
if [ "$CANDIDATES" -eq 1 ] && [ -n "$MODULE" ]; then
    dd if="$MODULE" of="$OUT/boot-dom.img" bs=1M conv=fsync status=none
    ( cd "$OUT" && sha256sum boot-dom.img >> SHA256SUMS )
    ok "module image written: $OUT/boot-dom.img ($(stat -c %s "$OUT/boot-dom.img") bytes)"
else
    bad "expected exactly one 100-200 MB vfat device, found $CANDIDATES"
    warn "on a running ReadyNASOS the module is unbound from usb-storage; from the"
    warn "rescue system it is a normal device. Do not guess: find it, then re-run."
fi

# --- 6. the ReadyNASOS root --------------------------------------------------
if [ "$SKIP_ROOT_TAR" = yes ]; then
    warn "skipping the ReadyNASOS root tar: the old /etc, users and frontview are gone after mkfs"
else
    ROOTDEV=""
    for d in /dev/md[0-9]*; do
        [ -b "$d" ] || continue
        [ "$(blkid -s TYPE -o value "$d" 2>/dev/null)" = ext4 ] || continue
        size=$(blockdev --getsize64 "$d")
        [ "$size" -le 12000000000 ] && { ROOTDEV=$d; break; }
    done
    if [ -n "$ROOTDEV" ]; then
        mkdir -p "$ROOT_MNT"
        mountpoint -q "$ROOT_MNT" || mount -o ro "$ROOTDEV" "$ROOT_MNT"
        tar -C "$ROOT_MNT" --one-file-system -czf "$OUT/readynasos-root.tar.gz" . 2>/dev/null || bad "tar failed"
        umount "$ROOT_MNT"
        ( cd "$OUT" && sha256sum readynasos-root.tar.gz >> SHA256SUMS )
        printf '%s %s\n' "$ROOTDEV" "$(blockdev --getsize64 "$ROOTDEV") bytes" > "$OUT/root-device.txt"
        ok "ReadyNASOS root archived from $ROOTDEV ($(blockdev --getsize64 "$ROOTDEV") bytes)"
        ok "that is the array to mkfs in the next step; it is recorded in root-device.txt"
    else
        bad "no small ext4 array found for the ReadyNASOS root"
    fi
fi

# --- 7. the per-share settings ----------------------------------------------
if [ "$MOUNTED" = yes ] && [ -d "$RAID_MNT/._share" ]; then
    tar -C "$RAID_MNT" -czf "$OUT/readynas-share-configs.tar.gz" ._share 2>/dev/null
    ( cd "$OUT" && sha256sum readynas-share-configs.tar.gz >> SHA256SUMS )
    ok "share settings: $(tar -tzf "$OUT/readynas-share-configs.tar.gz" | wc -l) files"
else
    warn "no ._share on the array: nothing to archive for the old share settings"
fi

# --- 8. done ----------------------------------------------------------------
[ "$MOUNTED" = yes ] && umount "$RAID_MNT"
sort -u -k2 "$OUT/SHA256SUMS" -o "$OUT/SHA256SUMS" 2>/dev/null || true
echo
echo "artefacts in $OUT:"
ls -l "$OUT"
echo
echo "Copy these off this machine and check them: cd $OUT && sha256sum -c SHA256SUMS"
echo
if [ "$FAIL" -eq 0 ]; then
    echo "GO. From here only md0 may be reformatted, and the module image is the"
    echo "only way back to the factory bootloader."
else
    echo "NO GO. Fix what is marked FAIL before touching any storage." >&2
    exit 1
fi
