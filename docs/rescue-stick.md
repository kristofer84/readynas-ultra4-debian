# Building the headless grml rescue stick

The only interactive shell this machine can give you is a live system booted with the front
Backup button. That live system has to be reachable with no video and no keyboard, which
stock grml is not. This is how the stick was made.

Files: [`../rescue/`](../rescue/). Verified working on a ReadyNAS Ultra 4 (2010 Atom,
Award/Phoenix BIOS, no external video).

## Why stock grml does not work here

Two independent failures, both measured on this machine.

**No networking.** grml's `/etc/network/interfaces` is loopback-only, there is no
`config_dhcp` handler in `grml-autoconfig`, and the initramfs only calls
`configure_networking()` for NFS/iSCSI/AoE roots. So grml boots, sshd starts, and the box
never gets an address. On hardware with no VGA that looks exactly like an unsupported NIC.

**No bootable partition table.** grml ships GRUB's `grub2-mbr` boot code but an all-zero MBR
partition table (checked in the upstream 2026.09 image, so this is grml's choice, not damage
from remastering). The 2011 BIOS here may simply not offer a partitionless disk as a boot
device.

## What the remaster adds

| file on the ISO | what it does |
|---|---|
| `boot/grub/grub_local_custom_early.cfg` | sets `$kernelopts`, which grml's default menu entry interpolates: `ssh=<password> scripts hostname=<name> noeject noprompt console=tty0 console=ttyS0,115200n8` |
| `boot/grub/grub_local_custom_pre_entry.cfg` | mirrors the GRUB menu to serial, harmless when nothing is attached |
| `boot/grub/grub_local_custom_late.cfg` | a second `toram` entry, only reachable over serial |
| `scripts/grml.sh` | brings the wired links up and does DHCP, then pings a known host so it can be found by ARP |

`grml.sh` is picked up because `config_finddcsdir` sets the dcs directory to the live medium
root (`/run/live/medium`) when no GRMLCFG partition exists, and the `scripts` boot option
runs whatever it finds there.

Both `early.cfg` and `grml.sh` in this repo carry placeholders: **`ssh=<password>`** and the
peer address in `grml.sh`. Set them before building. Then change the password on the GRUB
line, or better, keep it out of the ISO entirely and add it by hand at build time.

## Build

Needs `xorriso`. Do this on any Linux host with room for two 1.2 GB images.

```sh
ISO=grml-full-2026.09-amd64.iso
mkdir -p tree && xorriso -osirrox on -indev "$ISO" -extract / tree
chmod -R u+w tree

# password on the kernel command line, and the peer grml.sh pings
$EDITOR tree/boot/grub/grub_local_custom_early.cfg
$EDITOR tree/scripts/grml.sh
cp ../rescue/grub_local_custom_pre_entry.cfg ../rescue/grub_local_custom_late.cfg \
   tree/boot/grub/
cp ../rescue/grml.sh tree/scripts/ && chmod +x tree/scripts/grml.sh

xorriso -as mkisofs \
  -V 'grml-full-amd64 2026.09' \
  --grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt:"$ISO" \
  --protective-msdos-label \
  -boot_image any partition_table=on iso_mbr_part_type=0x00 mbr_force_bootable=on \
  partition_cyl_align=on \
  -c /boot.catalog \
  -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table \
  --grub2-boot-info \
  -eltorito-alt-boot \
  -e /boot/efi.img -no-emul-boot -boot-load-size 8192 \
  -o grml-headless.iso tree
```

Those El Torito options are what the working image reports, read back with
`xorriso -indev … -report_el_torito as_mkisofs`; the four `partition_*` flags are what was
added to make the BIOS accept it. GRUB's MBR code finds its core image by embedded LBA and
ignores the partition table, so filling bytes 446 to 509 cannot disturb it.

## Gate: check the image before you overwrite the working stick

```sh
xorriso -indev grml-headless.iso -report_el_torito as_mkisofs | grep -E 'grub2-mbr|protective|partition'
fdisk -l grml-headless.iso      # one partition, boot flag set, type 0
xorriso -indev grml-headless.iso -find /scripts -name 'grml.sh'
```

Then write it to the stick with `dd`, and boot it once with the Backup button while you
still have a machine you can rebuild from: hold Backup, press Power, keep holding through
POST (up to 15 s).

## Using it

1. Power off. **Hold the front Backup button first**, then press Power, and keep holding
   through POST. Releasing early is the same as not pressing it.
2. Wait for the DHCP lease, then find the box (`arp -a`, or the ping `grml.sh` sends at the
   peer).
3. `ssh root@<address>` with the password from the GRUB line.

`grml.sh` logs to `/var/log/grml-nas-netup.log` on the live system. If you get no address,
that file says whether networkd or the `dhcpcd` fallback got a lease.

The internal serial header is a working console if you ever have the case open: GRUB is
mirrored there and `console=ttyS0,115200n8` is on the kernel line.

One consequence of the partition layout, easy to trip over in a hurry: the partition starts
at LBA 1 while the ISO9660 filesystem starts at LBA 0, so `/dev/sdX1` will not mount.
**Mount the whole device.**
