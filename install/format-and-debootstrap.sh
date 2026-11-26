#!/bin/sh
# Replace the NAS's system with Debian, keeping the data.
#
# This is the only step that erases anything, so it is a script rather than a
# command you copy: it reads what preflight.sh found, refuses to touch anything
# that looks like the data array, checks it can reach a Debian mirror before it
# erases a single byte, and makes you type the device name to confirm.
#
#   format-and-debootstrap.sh --preflight /root/preflight
#
# Afterwards the new system is installed but not yet configured: run the
# chroot-configure.sh it prints. See START-HERE.md.
#
# NOT yet executed on a ReadyNAS. The commands are the ones recorded in
# docs/install.md, which were run by hand on 2026-09-08.
set -eu

PREFLIGHT=""
MAX_OS_BYTES=12000000000     # 12 GB: an OS array is 4 GB, a data array is terabytes
TARGET=/mnt/target

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
die()  { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --preflight) PREFLIGHT=${2:?}; shift 2 ;;
        -h|--help)   usage ;;
        *)           printf 'unknown argument: %s\n' "$1" >&2; usage ;;
    esac
done
[ -n "$PREFLIGHT" ] || usage

# --- 1. what preflight.sh recorded ------------------------------------------
[ -f "$PREFLIGHT/root-device.txt" ] || die "no root-device.txt in $PREFLIGHT: run install/preflight.sh first"
OSDEV=$(cut -d' ' -f1 "$PREFLIGHT/root-device.txt")
DATA=""
[ -f "$PREFLIGHT/data-device.txt" ] && DATA=$(cut -d' ' -f1 "$PREFLIGHT/data-device.txt")

[ -b "$OSDEV" ] || die "$OSDEV is not a block device now"
[ "$OSDEV" != "$DATA" ] || die "the system array and the data array are the same device ($OSDEV)"

SIZE=$(blockdev --getsize64 "$OSDEV")
[ "$SIZE" -le "$MAX_OS_BYTES" ] || die "$OSDEV is $SIZE bytes, which is not a system array. Refusing."

LEVEL=$(mdadm --detail "$OSDEV" | awk -F': ' '/Raid Level/ {print $2}')
case "$LEVEL" in
    raid1|raid10|"") ok "system array $OSDEV: $LEVEL, $SIZE bytes" ;;
    *) die "$OSDEV reports $LEVEL, which is how this machine's data array is built. Refusing." ;;
esac

# --- 2. can we reach a Debian mirror at all? --------------------------------
# Before, not after: a machine with no network and no system is the worst state
# to be in, and this takes ten seconds.
if ! { curl -fsI --max-time 20 http://deb.debian.org/debian/dists/trixie/Release >/dev/null 2>&1 \
       || wget -q --spider --timeout=20 http://deb.debian.org/debian/dists/trixie/Release 2>/dev/null; }; then
    die "cannot reach deb.debian.org from here. Fix the network first; nothing has been erased."
fi
ok "the Debian mirror answers"

# --- 3. say exactly what is about to go --------------------------------------
echo
echo "About to erase the operating system on:"
echo "    $OSDEV    $SIZE bytes, $LEVEL"
echo
if [ -n "$DATA" ]; then
    echo "The data array ($DATA) is NOT touched. It stays as it is."
else
    echo "No data array was recorded by preflight.sh."
fi
echo
echo "Everything on $OSDEV (the NAS's own system, settings and users) is destroyed."
echo "You cannot undo this. The copies preflight.sh took are what is left."
echo
printf 'Type this exactly to continue: ERASE %s\n> ' "$OSDEV"
read -r answer
[ "$answer" = "ERASE $OSDEV" ] || die "not confirmed; nothing was erased"

# --- 4. build the new system ------------------------------------------------
echo
echo "Formatting $OSDEV ..."
mkfs.ext4 -q -L debian-root "$OSDEV"

mkdir -p "$TARGET"
mount "$OSDEV" "$TARGET"

echo "Installing Debian into it. On this hardware this takes 15 to 25 minutes,"
echo "most of it downloading. Do not close the window; if the connection drops,"
echo "reconnect and watch: tail -f /var/log/bootstrap.log"
echo
debootstrap trixie "$TARGET" http://deb.debian.org/debian 2>&1 | tail -5

[ -f "$TARGET/var/log/bootstrap.log" ] || die "debootstrap finished without a log: check $TARGET before going on"
ok "Debian installed: $(grep -c 'Setting up' "$TARGET/var/log/bootstrap.log") packages"

# --- 5. make it reachable and self-contained --------------------------------
mount --bind /dev  "$TARGET/dev"
mount --bind /proc "$TARGET/proc"
mount --bind /sys  "$TARGET/sys"
cp /etc/resolv.conf "$TARGET/etc/resolv.conf"
ok "the new system is mounted at $TARGET"

# The configuration script lives in the new system's /root, so it is there both
# for the chroot below and for postinstall.sh after the first boot.
REPO_DIR="$TARGET/root/readynas-ultra4-debian"
if [ ! -d "$REPO_DIR" ]; then
    mkdir -p "$TARGET/root"
    if git clone -q https://github.com/kristofer84/readynas-ultra4-debian "$REPO_DIR" 2>/dev/null; then
        ok "this repository copied into the new system: $REPO_DIR"
    else
        die "could not clone the repository into the new system; copy it by hand to $REPO_DIR"
    fi
fi

echo
echo "Done. The next command configures the new system. It needs a way for you to"
echo "log in. Simplest is to let it generate a password:"
echo
echo "  chroot $TARGET $REPO_DIR/install/chroot-configure.sh --hostname nas"
echo
echo "or, to log in with your own key, copy the public key in first so the chroot"
echo "can see it:"
echo
echo "  cp id_ed25519.pub $TARGET/root/"
echo "  chroot $TARGET $REPO_DIR/install/chroot-configure.sh \\"
echo "      --hostname nas --root-key /root/id_ed25519.pub"
echo
