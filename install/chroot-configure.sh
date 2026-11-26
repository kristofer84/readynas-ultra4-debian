#!/bin/sh
# Configure the new Debian root. Run INSIDE the chroot, after debootstrap and
# after /dev, /proc and /sys are bound, before the boot module is touched.
#
#   chroot-configure.sh --hostname nas [--timezone Europe/Stockholm]
#                       [--root-key /path/to/id_ed25519.pub] [--root-password PW]
#
# It installs the package set, writes /etc/fstab from blkid so that no UUID is
# typed by hand, generates mdadm.conf, sets MODULES=dep, writes the networkd
# file, and enables the units one at a time. Then it gates on two things that
# decide whether the machine boots: an initrd that can reach md0, and an fstab
# whose UUIDs all resolve.
#
# NOT yet executed on a ReadyNAS. The commands are the ones recorded in
# docs/install.md, which were run by hand on 2026-09-08.
set -eu

NAS_HOSTNAME=nas
TIMEZONE=""
ROOT_KEY=""
ROOT_PASSWORD=""
FAIL=0

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=1; }
die()  { printf 'FAIL  %s\n' "$*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname) NAS_HOSTNAME=${2:?}; shift 2 ;;
        --timezone) TIMEZONE=${2:?}; shift 2 ;;
        --root-key) ROOT_KEY=${2:?}; shift 2 ;;
        --root-password) ROOT_PASSWORD=${2:?}; shift 2 ;;
        -h|--help)  usage ;;
        *)          printf 'unknown argument: %s\n' "$1" >&2; usage ;;
    esac
done

[ -d /etc/initramfs-tools ] || die "this is not the new root: run it inside the chroot"
[ -f /var/log/bootstrap.log ] || warn "no /var/log/bootstrap.log: was this debootstrapped here?"

echo "chroot-configure: hostname=$NAS_HOSTNAME"

# --- 1. packages -------------------------------------------------------------
# initramfs-tools first and on its own, so the kernel's postinst has something
# to call.
apt-get install -y -qq initramfs-tools
apt-get install -y -qq linux-image-amd64 mdadm btrfs-progs openssh-server sudo \
    nfs-kernel-server samba smartmontools systemd-timesyncd ethtool usbutils \
    pciutils rsync ca-certificates lm-sensors fancontrol
# Separate transaction: in trixie this is its own package, and enabling it
# before it exists fails a whole systemctl call (see docs/gotchas.md).
apt-get install -y -qq systemd-resolved
ok "packages installed"

# --- 2. fstab, built from what is actually on the disks ----------------------
ROOTDEV=$(blkid -L debian-root 2>/dev/null || true)
[ -n "$ROOTDEV" ] || ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOTUUID=$(blkid -s UUID -o value "$ROOTDEV" 2>/dev/null || true)
[ -n "$ROOTUUID" ] || die "cannot read the UUID of the root filesystem"

# swap: first swap-typed device, if any
SWAPUUID=""
for d in $(blkid -t TYPE=swap -o device 2>/dev/null); do
    SWAPUUID=$(blkid -s UUID -o value "$d"); break
done

# the data array: the btrfs (or ext4/xfs) array that is not the root
RAIDUUID=""
RAIDTYPE=""
for d in $(blkid -t TYPE=btrfs -o device 2>/dev/null) \
         $(blkid -t TYPE=ext4 -o device 2>/dev/null); do
    uuid=$(blkid -s UUID -o value "$d")
    [ "$uuid" = "$ROOTUUID" ] && continue
    RAIDUUID=$uuid; RAIDTYPE=$(blkid -s TYPE -o value "$d"); break
done
[ -n "$RAIDUUID" ] || warn "no data array found: /raid will be left out of fstab"

{
    echo "# Written by chroot-configure.sh from blkid on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo "# Everything by UUID: md device numbering is not stable across kernels."
    echo "UUID=$ROOTUUID   /       ext4    errors=remount-ro,noatime   0 1"
    if [ -n "$SWAPUUID" ]; then
        echo "UUID=$SWAPUUID   none    swap    sw                          0 0"
    fi
    if [ -n "$RAIDUUID" ]; then
        opts="defaults,noatime"
        # space_cache=v2 up front: the v1 default is deprecated and converting
        # later needs the array read-only, which means stopping every client.
        if [ "$RAIDTYPE" = btrfs ]; then opts="$opts,space_cache=v2"; fi
        echo "UUID=$RAIDUUID   /raid   $RAIDTYPE   $opts  0 0"
    fi
} > /etc/fstab
ok "fstab written: root $ROOTUUID, raid ${RAIDUUID:-none} ($RAIDTYPE)"

# --- 3. mdadm.conf -----------------------------------------------------------
mdadm --detail --scan > /etc/mdadm.conf
if grep -q '^HOMEHOST' /etc/mdadm.conf; then
    sed -i 's/^HOMEHOST.*/HOMEHOST <ignore>/' /etc/mdadm.conf
else
    sed -i '1i HOMEHOST <ignore>' /etc/mdadm.conf
fi
ok "mdadm.conf: $(grep -c '^ARRAY' /etc/mdadm.conf) arrays, HOMEHOST <ignore>"

# --- 4. identity -------------------------------------------------------------
echo "$NAS_HOSTNAME" > /etc/hostname
grep -q "^127.0.1.1" /etc/hosts || echo "127.0.1.1 $NAS_HOSTNAME" >> /etc/hosts
if [ -n "$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
    ok "timezone $TIMEZONE"
fi

# --- 5. networking -----------------------------------------------------------
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-wired.network <<'EOF'
# Wildcard match on purpose: this box is headless, and an interface rename that
# no file matches strands it with no way in but the Backup button.
[Match]
Name=en*

[Network]
DHCP=yes
EOF
# The second NIC is routinely uncabled; without this wait-online waits for it
# and blocks network-online.target, nfs-server, smbd and multi-user.target.
DROPIN=/etc/systemd/system/systemd-networkd-wait-online.service.d
mkdir -p "$DROPIN"
cat > "$DROPIN/any.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=30
EOF
ok "networkd config and wait-online drop-in written"

# --- 6. initramfs ------------------------------------------------------------
# MODULES=dep gives a 12.9 MB initrd where MODULES=most gives ~56 MB, and the
# module is 120 MB with room for two kernels.
if grep -q '^MODULES=' /etc/initramfs-tools/initramfs.conf; then
    sed -i 's/^MODULES=.*/MODULES=dep/' /etc/initramfs-tools/initramfs.conf
else
    echo 'MODULES=dep' >> /etc/initramfs-tools/initramfs.conf
fi
ok "initramfs.conf: MODULES=dep"

update-initramfs -u
INITRD=$(ls -1t /boot/initrd.img-* 2>/dev/null | head -1)
[ -n "$INITRD" ] || die "no initrd in /boot after update-initramfs"
LIST=$(lsinitramfs "$INITRD")
MISSING=""
for piece in ahci raid1 raid456 md-mod ext4 sd_mod mdadm; do
    echo "$LIST" | grep -q "$piece" || MISSING="$MISSING $piece"
done
if [ -n "$MISSING" ]; then
    bad "initrd cannot reach md0, missing:$MISSING"
else
    ok "initrd $(basename "$INITRD") has ahci raid1 raid456 md-mod ext4 sd_mod mdadm"
fi

# --- 7. a way in -------------------------------------------------------------
# debootstrap leaves root with no password, and Debian's sshd refuses password
# logins for root by default. Without one of these the machine boots, sshes
# nowhere, and the only remaining door is the Backup button.
GENERATED=""
if [ -n "$ROOT_KEY" ]; then
    [ -f "$ROOT_KEY" ] || die "no such key file: $ROOT_KEY"
    install -d -m 0700 /root/.ssh
    cat "$ROOT_KEY" >> /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    ok "root key installed from $(basename "$ROOT_KEY")"
elif [ -n "$ROOT_PASSWORD" ]; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
    ok "root password set from --root-password"
else
    ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
    GENERATED=yes
    warn "no --root-key and no --root-password: generated one, printed below"
fi
if passwd -S root 2>/dev/null | grep -q '^root P ' || [ -s /root/.ssh/authorized_keys ]; then
    ok "root can log in"
else
    bad "root has neither a password nor an authorised key: nobody can log in"
fi

# --- 8. enable, one unit at a time -------------------------------------------
for unit in systemd-networkd systemd-resolved ssh nfs-server smbd; do
    if systemctl enable "$unit" >/dev/null 2>&1; then
        ok "enabled $unit"
    else
        bad "could not enable $unit"
    fi
done

# --- 9. gate -----------------------------------------------------------------
while read -r spec _ _ _; do
    case "$spec" in UUID=*) ;; *) continue ;; esac
    uuid=${spec#UUID=}
    blkid -U "$uuid" >/dev/null 2>&1 || bad "fstab UUID $uuid resolves to no device"
done < /etc/fstab
if [ "$FAIL" -eq 0 ]; then ok "every fstab UUID resolves"; fi

echo
if [ -n "$GENERATED" ]; then
    echo "  root password: $ROOT_PASSWORD"
    echo "  Write it down now. It is in /etc/shadow and nowhere else, and the only"
    echo "  other way in is the rescue stick."
    echo
fi
if [ "$FAIL" -eq 0 ]; then
    echo "Configured. Next: install/boot-module.sh --root <mountpoint of the new root>, from the rescue system."
else
    echo "There are failures above. Do not boot the module until they are fixed." >&2
    exit 1
fi
