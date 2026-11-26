#!/bin/sh
# Executed by grml-autoconfig's config_scripts() from /run/live/medium/scripts/grml.sh
# because the 'scripts' boot option is set.
#
# grml does NOT configure networking on its own: /etc/network/interfaces contains
# only loopback, there is no config_dhcp handler, and the initramfs only runs
# configure_networking() for NFS/iSCSI/AoE roots. On a headless machine with no
# VGA that means a successful boot is indistinguishable from a failed one.
# This script brings the wired interfaces up and announces the box on the LAN.

LOG=/var/log/grml-nas-netup.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) grml.sh starting ==="

PEER=CHANGEME               # a host on this LAN that answers a ping

for i in /sys/class/net/*; do
    n=${i##*/}
    [ "$n" = lo ] && continue
    echo "bringing up link: $n"
    ip link set "$n" up 2>&1
done

# Preferred path: systemd-networkd (built-in DHCP client, no extra daemon).
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/50-dhcp-all.network <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF
systemctl start systemd-networkd 2>&1

# Give DHCP a chance, then fall back to dhcpcd if nothing got an address.
i=0
while [ $i -lt 20 ]; do
    if ip -4 addr show scope global | grep -q 'inet '; then break; fi
    sleep 1
    i=$((i + 1))
done

if ! ip -4 addr show scope global | grep -q 'inet '; then
    echo "networkd got no lease after ${i}s, falling back to dhcpcd"
    for i in /sys/class/net/*; do
        n=${i##*/}
        [ "$n" = lo ] && continue
        dhcpcd -n -t 20 "$n" 2>&1 &
    done
    sleep 20
fi

echo "--- resulting addresses ---"
ip -4 -o addr show 2>&1
ip -4 route 2>&1

# Announce ourselves so you can find the box by ARP even if DHCP naming does
# not cooperate. Set PEER to something on the LAN that answers a ping.
( for _ in $(seq 1 120); do ping -c 1 -W 2 "$PEER" >/dev/null 2>&1; sleep 5; done ) &

echo "=== $(date -Is) grml.sh done ==="
