#!/bin/sh
# The part the install still owes once the machine boots on its own.
# Run on the new system, as root, with a checkout of this repository available.
#
#   postinstall.sh --repo /root/readynas-ultra4-debian
#
# Installs the four /usr/local/sbin scripts, the units, the hooks, the module
# loaders and the fan-control drop-in; then checks that each one is actually
# doing something rather than merely active.
#
# It does not touch /etc/exports or /etc/samba/smb.conf. Those carry decisions
# about your network and your users, and config/exports is an example with
# placeholder addresses; read it, then write your own.
#
# NOT yet executed on a ReadyNAS. The commands are the ones recorded in
# docs/install.md and docs/gotchas.md.
set -eu

REPO=""
FAIL=0

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=1; }
die()  { printf 'FAIL  %s\n' "$*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)    REPO=${2:?}; shift 2 ;;
        -h|--help) usage ;;
        *)         printf 'unknown argument: %s\n' "$1" >&2; usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run this as root"
[ -n "$REPO" ] || REPO=$(cd "$(dirname "$0")/.." && pwd)
[ -d "$REPO/scripts" ] || die "$REPO is not a checkout of this repository"
echo "postinstall: repo=$REPO"

# --- 1. the scripts ----------------------------------------------------------
for s in sync-boot-to-dom backup-root nas-fancontrol md-event; do
    install -m 0755 "$REPO/scripts/$s" /usr/local/sbin/"$s"
done
ok "four scripts in /usr/local/sbin"

# --- 2. the units ------------------------------------------------------------
for u in "$REPO"/systemd/*.service "$REPO"/systemd/*.timer; do
    [ -f "$u" ] || continue
    install -m 0644 "$u" /etc/systemd/system/
done
ok "units in /etc/systemd/system"

# --- 3. module loaders and the fan-control drop-in ---------------------------
mkdir -p /etc/modules-load.d /etc/systemd/system/nas-fancontrol.service.d
install -m 0644 "$REPO/config/modules-load.d/it87.conf" /etc/modules-load.d/
install -m 0644 "$REPO/config/modules-load.d/drivetemp.conf" /etc/modules-load.d/
install -m 0644 "$REPO/config/nas-fancontrol.service.d/modprobe.conf" \
    /etc/systemd/system/nas-fancontrol.service.d/
modprobe it87 && ok "it87 loaded" || bad "it87 will not load: the fan stays at full speed"
modprobe drivetemp && ok "drivetemp loaded" || bad "drivetemp will not load: no disk temperatures"

# --- 4. hooks, and only with the script they call ---------------------------
# A hook that execs a missing script fails the kernel postinst, so these are
# installed here and not before.
mkdir -p /etc/kernel/postinst.d /etc/initramfs/post-update.d
install -m 0755 "$REPO/hooks/kernel-postinst.d/zz-sync-boot-to-dom" /etc/kernel/postinst.d/
install -m 0755 "$REPO/hooks/initramfs-post-update.d/zz-sync-boot-to-dom" /etc/initramfs/post-update.d/
ok "both zz-sync-boot-to-dom hooks, with the script they call"

# --- 5. mdmonitor, which refuses to start without a program -----------------
if ! grep -q '^PROGRAM' /etc/mdadm/mdadm.conf 2>/dev/null; then
    echo 'PROGRAM /usr/local/sbin/md-event' >> /etc/mdadm/mdadm.conf 2>/dev/null \
        || warn "no /etc/mdadm/mdadm.conf: add PROGRAM /usr/local/sbin/md-event where yours is"
fi

systemctl daemon-reload
for unit in nas-fancontrol.service md-stripe-cache.service backup-root.timer mdmonitor.service; do
    systemctl enable --now "$unit" >/dev/null 2>&1 || warn "could not start $unit"
done

# --- 6. gates: is each of them doing something? -----------------------------
for unit in nas-fancontrol.service mdmonitor.service; do
    if systemctl is-active --quiet "$unit"; then ok "$unit active"; else bad "$unit not active"; fi
done
systemctl is-enabled --quiet backup-root.timer && ok "backup-root.timer enabled" \
    || bad "backup-root.timer not enabled"

# The fan is the one that looks healthy while doing nothing: the unit is active,
# there is no it8721 hwmon, and pwm1 stays at 255.
IT=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat "$d/name" 2>/dev/null)" = it8721 ] && echo "$d"; done | head -1)
if [ -n "$IT" ]; then
    ok "it8721 at $IT, pwm1=$(cat "$IT/pwm1" 2>/dev/null) pwm1_enable=$(cat "$IT/pwm1_enable" 2>/dev/null)"
    if [ "$(cat "$IT/pwm1" 2>/dev/null)" = 255 ]; then
        warn "pwm1 is 255: either hot, or nas-fancontrol is not driving it"
    fi
else
    bad "no it8721 hwmon: nas-fancontrol is active and doing nothing"
fi
DT=$(ls -d /sys/class/hwmon/hwmon* 2>/dev/null | while read -r d; do [ "$(cat "$d/name" 2>/dev/null)" = drivetemp ] && echo "$d"; done | wc -l)
if [ "$DT" -gt 0 ]; then ok "$DT drivetemp sensors"; else bad "no drivetemp sensors: the fan has nothing to read"; fi

# space_cache: v2 should have been in fstab from the first boot
if grep -q 'space_cache=v2' /etc/fstab; then
    ok "fstab pins space_cache=v2"
else
    warn "fstab has no space_cache=v2: the array will mount with the deprecated v1"
fi
grep -q ' /raid ' /proc/mounts || warn "/raid is not mounted: backup-root and the exports need it"

echo
echo "Not done here, on purpose: /etc/exports and /etc/samba/smb.conf. Read"
echo "\"The ported exports carried an old grant\" in docs/gotchas.md before copying"
echo "either of them from an old machine."
echo
if [ "$FAIL" -eq 0 ]; then
    echo "Done. Then the verification table in CHECKLIST.md, and a reboot with nobody watching."
else
    echo "See FAIL above." >&2
    exit 1
fi
