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

`grml.sh` carries no peer address by default and skips the ARP beacon when `GRML_PEER` is
empty, so a published image does not depend on someone else's LAN.

## What the password is for

`ssh=` is a grml-autoconfig boot option: grml starts sshd and sets that password on **root**
and on the **grml** user. It is the credential for the rescue system itself, so it is the
only thing between the network and a root shell on the machine whose data array is on the
other side of that shell.

The shipped value is `changeme`, and it is not a secret:

- it is visible in the GRUB menu, on the serial console, and in `cat /proc/cmdline` inside
  the live system;
- while the stick is booted, anyone who can reach the machine on the same L2 segment can log
  in as root with it.

That is acceptable for a stick you boot yourself on your own bench, which is the case this
image was made for. It is not acceptable for a machine left booted somewhere shared. Set
`SSH_PASSWORD` at build time if you want anything else, and note that a custom password is
not recorded in `BUILD-INFO.txt` on purpose, so the published checksums only ever describe
the default.

Nothing persists across a reboot: the live system runs from RAM, and the password lives only
on the kernel command line of the running instance.

## Build

```sh
./build/build-iso.sh            # fetches the pinned upstream image, builds dist/
./build/verify-iso.sh dist/readynas-rescue-2026.09-amd64.iso changeme
```

Needs `xorriso`, `curl` and `python3`, and 3 GB of scratch space. `GRML_ISO=/path/to.iso`
builds from a local copy instead of downloading.

| variable | default | what it does |
|---|---|---|
| `GRML_VERSION` | `2026.09` | grml release; its hash must be in [`../build/upstream.sha256`](../build/upstream.sha256) |
| `SSH_PASSWORD` | `changeme` | password for root and `grml` in the live system, see above |
| `RESCUE_HOSTNAME` | `grmlnas` | hostname the live system reports |
| `GRML_PEER` | empty | an address to ping every 5 s, so the box can be found by ARP; empty skips it |
| `SOURCE_DATE_EPOCH` | `1788436673` | timestamp written to every file and to the volume header |
| `XORRISO_PIN` | unset | fail unless xorriso is this version, so a build cannot silently differ from a published checksum |

Two things the script does that are easy to get wrong by hand:

- **`-as mkisofs`, not native xorriso.** The El Torito and partition options below are the
  emulation's spelling, and it is what the recorded image reports
  (`xorriso -indev … -report_el_torito as_mkisofs`).
- **The MBR partition type is patched afterwards.** The recorded run had
  `iso_mbr_part_type=0x00`, the layout Debian's own ISOs use: partition 1, active, spanning
  the image, type 0. `-as mkisofs` writes `0xcd` and has no option for the type, so the
  build writes that single byte at offset 450. `verify-iso.sh` fails if it is not 0.

The flags, for reference:

```
-r --set_all_file_dates set_to_mtime --modification-date=<SOURCE_DATE_EPOCH as YYYYMMDDhhmmsscc>
--grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt:<upstream.iso> --protective-msdos-label
-partition_cyl_align on -partition_offset 0 --mbr-force-bootable
-c /boot.catalog -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table
--grub2-boot-info -eltorito-alt-boot -e /boot/efi.img -no-emul-boot -boot-load-size 8192
```

GRUB's MBR code finds its core image by embedded LBA and ignores the partition table, so
filling bytes 446 to 509 cannot disturb it.

## Verifiable build

The image is not published. What is published is a sha256 that you can check by building it
yourself, which is only worth anything if the build is reproducible. It is, under three
conditions:

| condition | how it is pinned |
|---|---|
| the upstream grml image | `build/upstream.sha256`, checked before anything is unpacked |
| every timestamp in the output | `SOURCE_DATE_EPOCH`, applied to all files and to the volume header, with xorriso copying mtime into atime and ctime |
| the toolchain | `XORRISO_PIN`; the CI job runs in `debian:trixie-slim` and pins 1.5.6 |

`-r` normalises ownership and permissions to root and read-only, so building as root and as
a normal user gives the same bytes. Building from a different directory does too.

Measured on 2026-11-26: four builds (two consecutive, one as root, one into a different
workspace) of grml 2026.09 with xorriso 1.5.6 produced
`3b0397e25c69c093a713224e257ec221a4290f30706f99f8cdced5ae2211b6bb`. Not measured: the same
build on x86_64, which is what CI runs, or with a different xorriso. If a rebuild differs,
compare `dist/BUILD-INFO.txt` first: it records the upstream hash, the source date, the
xorriso version and the build host.

`.github/workflows/iso.yml` runs the same two scripts on every change to `build/` or
`rescue/`, and uploads `SHA256SUMS`, `BUILD-INFO.txt` and `verify.log` as the only artifact.

## What verify-iso.sh checks, and what it cannot

```
ok size 1154236416
ok    MBR: boot signature, one active partition, type 0x00
ok El Torito: grub2-mbr
ok El Torito: BIOS entry at /boot/grub/i386-pc/eltorito.img
ok El Torito: UEFI entry present
ok present: grml.sh
ok present: early.cfg
ok present: pre.cfg
ok present: late.cfg
ok password substituted in early.cfg
ok serial menu mirroring in place
ok grml.sh carries a PEER line
```

That is the structure. **It does not prove the image boots**, and no check on the file can:
the first boot needs the Backup button on the machine itself. Do that once while you still
have a machine you can rebuild from: hold Backup, press Power, keep holding through POST (up
to 15 s).

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
