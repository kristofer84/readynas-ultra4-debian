# ReadyNAS Ultra 4: boot chain and recovery

How this machine starts, how to get a rescue system onto it, and how to put it back.
**Read this before changing anything about how it boots** - there is no bootloader on the
disks and no console, and both facts decide what you can and cannot recover from.

How Debian was put onto it - the `debootstrap` run and the module rewrite - is in
[install.md](install.md). The rescue medium is built in [rescue-stick.md](rescue-stick.md).

## There is no bootloader on the hard disks

sda's MBR is zeroed apart from the protective GPT entry, and `/boot` on the running system
is not the boot medium. The machine boots from a **hidden internal 120 MB USB flash module**
(SMI Corporation `090c:1000`) on USB port `2-1`. The serial differs per unit; address it
by-id or by size, never by `/dev/sdX`.

It presents as a single bootable **FAT16** partition running **syslinux**. Under the current
Debian install it is simply `/dev/sde`. Its contents now:

```
LDLINUX.SYS   syslinux, installed by NETGEAR in 2013 and left in place
SYSLINUX.CFG  rewritten 2026-09-08 to boot Debian
VMLINUZ       Debian kernel   (12.1 MB)
INITRD.IMG    Debian initrd   (12.9 MB)
MEMTEST       kept from the factory image
VERSION.TXT   stale, still says RAIDiator 4.2.31 - ignore it
vpd           512 bytes of NETGEAR vital product data
```

25 MB of 120 MB used. The syslinux **bootloader itself was never reinstalled** - only the
config and the kernel files were replaced, which is the lowest-risk change that works, since
FAT does not relocate existing files and `LDLINUX.SYS` stays where its boot sector expects.

Keeping the initrd small enough matters: `MODULES=dep` in
`/etc/initramfs-tools/initramfs.conf` produces a 12.9 MB initrd where the default
`MODULES=most` would produce something closer to grml's 56 MB. Verified to contain `ahci`,
`raid1`, `raid456`, `md-mod`, `ext4`, `sd_mod`, the `mdadm` binary and `mdadm.conf` -
everything needed to reach the root array. `usb-storage` and `sky2` are absent and that is
correct; they load from the real root.

### ReadyNASOS hid this module; Debian does not

Under ReadyNASOS the initrd **unbound the module from `usb-storage` after boot**, so it did
not appear in `lsblk`, `/dev/sd*` or `/sys/block` on a running system - it was easy to
conclude it did not exist. It was still visible in `/sys/bus/usb/devices/2-1/`. The
responsible code is `get_boot_usb_path`, an imported symbol from `libreadynas.so.0`.

If you are ever running ReadyNASOS again and need to see it, bind it read-only:

```sh
echo -n "2-1:1.0" > /sys/bus/usb/drivers/usb-storage/bind    # appears as a new /dev/sdX
sleep 5
mount -o ro /dev/sdX1 /mnt/somewhere
...
umount /mnt/somewhere
echo -n "2-1:1.0" > /sys/bus/usb/drivers/usb-storage/unbind  # restore original state
```

Always unbind afterwards - leaving it bound is not how ReadyNASOS expects to find itself.
Under Debian none of this applies; it is a normal block device.

## Booting external media: hold the front Backup button

**The BIOS boot-device override is the front-panel Backup button.** This is the single most
useful fact about the machine and it is not in NETGEAR's documentation - it was found on
[the unRAID forum](https://forums.unraid.net/topic/140095-installing-unraid-on-a-readynas-ultra-4/):

> "Problem with the Readynas is that you must press the 'backup' button in order to boot
> from a USB key."

Procedure - the **ordering matters more than the duration**:

1. Power the NAS off.
2. **Press and hold Backup first**, before touching power. Pressing power first and then
   reaching for Backup is too late; the BIOS has already passed its read window.
3. Press Power, still holding Backup.
4. Keep holding through POST - up to 15 s, or up to 30 s on LCD units, which confirm on the
   display that they are attempting USB boot.
5. Release.

A short hold does nothing. This is the same mechanism NETGEAR's USB Recovery Tool relies on:
the tool's stick is booted by the BIOS, and the recovery image on it then reflashes the
module.

**Do not use the rear pinhole for this.** That is Reset, which enters the ReadyNASOS LCD
boot menu, where Factory Default sits one scroll away. It cannot boot external media anyway.

## What breaks, and what fixes it

Start here. The severity ladder, worst case at the bottom - and note that **`/raid` is on a
different array from the OS in every one of these**, which is the whole reason the migration
was safe.

| symptom | fix | cost |
|---|---|---|
| Bad kernel, will not boot | grml, mount the module, `cp VMLINUZ.OLD VMLINUZ` and `cp INITRD.OLD INITRD.IMG` | two file copies |
| Broken packages, still boots | fix in place, or grml + `chroot` to run apt with the system not running | minutes |
| Root filesystem wrecked | grml, `mkfs.ext4 /dev/md0` if needed, untar the weekly snapshot, re-run `sync-boot-to-dom` | back to last Sunday |
| Boot module corrupted | restore your saved image of the module (see [Backup artefacts](#backup-artefacts)) | back to ReadyNASOS bootloader |
| Start again from stock | that image plus the archived ReadyNASOS root | the 2019 NAS |

### The fallback kernel

`/usr/local/sbin/sync-boot-to-dom` keeps the outgoing kernel as `VMLINUZ.OLD` /
`INITRD.OLD` on the module - 48 MB of 120 used for two kernels.

It preserves the fallback **only when the kernel actually changes**. An initramfs
regeneration on an unchanged kernel must not consume the one known-good pair, so the script
compares first and skips the rotation if they match.

This matters because **there is no console here to pick a different syslinux entry**. A
second boot menu entry would be useless - nothing can select it. So the fallback is a pair
of files to copy back over the live ones from grml, not a menu option.

### The weekly root snapshot

`backup-root.timer` → `/usr/local/sbin/backup-root`, Sundays 03:00, `ionice idle`, keeping
three generations at `/raid/other/backup/debian-root/` with a sha256 beside each.

Deliberately written to `/raid` (md127) - a **different array** from the md0 it backs up.
First run: 422 MB, 35,975 entries, 6 minutes.

Restore is a plain untar; verify the archive carries the things that are painful to rebuild
before trusting it:

```sh
tar -tzf md0-debian-root-*.tar.gz | grep -E '^\./etc/(fstab|exports|samba/smb.conf)$'
```

### Before you upgrade

`sync-boot-to-dom` runs automatically from `/etc/kernel/postinst.d/` on every kernel
install, so **a kernel upgrade changes what boots**. Nothing to do by hand, but upgrade when
you are in a position to hold the Backup button - not remotely before travelling.

## Recovery runbook

In order of preference.

### 1. grml rescue stick + Backup button

The proven route, and the reason the boot-module rewrite was safe to attempt at all. Hold
Backup as above and a prepared grml stick boots a full rescue system with SSH, which is the
only interactive shell this machine can offer. Building that stick is
[rescue-stick.md](rescue-stick.md): stock grml will not do, for two independent reasons.

One consequence, easy to trip over in a hurry: the partition starts at LBA 1 while the
ISO9660 filesystem starts at LBA 0, so `/dev/sdX1` will not mount. **Mount the whole
device.**

### 2. Restore the boot module

An image of the module taken before any change, `<date>` being when you took it, is a
byte-for-byte copy of what NETGEAR left. Restoring it puts ReadyNASOS's bootloader back -
but md0 no longer holds ReadyNASOS, so pair it with the module's OS Reinstall boot option to
go fully back to stock.

Written from a rescue system with the module unmounted:

```sh
DOM=/dev/disk/by-id/usb-SMI_USB_DISK_<SERIAL>-0:0
[ "$(blockdev --getsize64 "$DOM")" = 125304832 ] || { echo wrong device; exit 1; }
dd if=boot-dom-<date>.img of="$DOM" bs=1M conv=fsync
```

Address it **by-id**, never by `/dev/sdX`: the names shift between boots. The size check is
there so a wrong target cannot be written to, and it should stay in any version of this you
run.

### 3. The archived ReadyNASOS root

`readynasos-root-<date>.tar.gz`: the complete factory root filesystem, 16 654 entries in the
recorded run, taken read-only before md0 was rebuilt. It holds `/etc/exports`,
`/etc/samba/smb.conf`, `passwd`, `group`, `shadow`, `fstab`, `network/interfaces` and the
whole frontview stack, if any of the old configuration is ever wanted again.

### Backup artefacts

Take these before md0 is touched, and keep at least one copy off the machine. Sizes are from
the recorded run.

| artefact | size | why |
|---|---|---|
| image of the internal boot module | 120 MB device | the only way back to the factory bootloader |
| tar of the ReadyNASOS root (md0) | 366 MB, 16 654 entries | the old config, taken read-only |
| tar of each share's `._share` settings | 1.7 KiB | the only record of how AFP/FTP shares were set up |
| the remastered grml ISO | 1.2 GB | rebuildable with `../build/build-iso.sh`, but not quickly |

`sha256sum` each one into a `SHA256SUMS` beside it and verify before you rely on it. The
grml upstream sums are GPG-signed by release key
`33CC B136 401A FEC8 43A3 8763 96A8 7872 B7EA 3737`, with the usual caveat that the sums
and the key come from the same host unless you fetch one of them independently.

## Ruled out - do not re-litigate these

Each was tested and closed with evidence. Recorded so the next person does not spend a day
rediscovering them.

### Changing the USB boot order by moving the stick - no

Three external sockets tried across three reboots. Every one enumerates on **`00:1d.7`
(usb2)** when it negotiates properly, and the internal module holds **port 1** of that same
controller, so the BIOS reaches it first every time.

One socket transiently came up as `6-1` on the UHCI companion `00:1d.1` at 12 Mbit/s, which
looked like a different controller worth testing. That was a **bad speed negotiation, not
the port's wiring** - on the next boot the same socket enumerated as `2-3` at 480 Mbit/s,
measured at 29.5 MB/s. Do not draw conclusions from a single enumeration.

### BIOS setup - not reachable without opening the case

The board has a VGA output (`card0-VGA-1`, disabled) and a real UART (`ttyS0` at 0x3f8),
but **both are internal headers**. Legacy BIOS keeps boot order in CMOS in an undocumented
vendor layout and `/dev/nvram` is not present, so there is no software route either.

If the case is ever open, the unRAID thread reports success with a VGA adapter on the
internal header: *"Disable all Hard Disk Drives, except the Unraid USB"* and *"Ensure that
Boot Device Priority shows Unraid USB."* Serial console also works for BIOS on this board.
That would be the permanent fix, making the Backup button unnecessary - but it is not
needed, because the bootloader now lives on the module the BIOS already prefers.

### PXE / network boot - not available

Confirmed by passive packet capture across a full POST window. The only DHCP traffic from
`02:00:00:00:00:01` was `Vendor-Class: "udhcp 1.24.1"` - BusyBox's client, i.e. the OS
initrd - with **zero `PXEClient` packets**. A real PXE ROM identifies as
`PXEClient:Arch:00000:UNDI:002001` and requests options 43/66/67. The option ROM is absent
or disabled.

Worth noting the trap: that early DHCP happens ~18 s into boot and the responder answers
ping, which can easily be mistaken for "the machine is back up".

### The LCD boot menu - cannot boot external media

Rendered by the ReadyNASOS initrd, i.e. *after* the internal module has already booted, so
it can never hand control elsewhere. Its entries are `Normal`, `Tech Support`,
`Memory Test`, `Test Disks`, `OS Reinstall`, plus Factory Default behind a separate
confirmation. The boot-reason parser in `/init` accepts exactly `normal`, `factory`, `diag`,
`vol_ro`, `test_disks`, `rescue` - no USB-boot reason exists.

`Legacy Boot Mode` in that binary is an LCD status label for old Ultra/Pro hardware running
OS6 (i.e. this machine), not a menu option.

### The NETGEAR USB Recovery Tool - a data-loss trap here

`RNDU4000` **is** listed as supported by the
[RAIDiator 4.2 USB Recovery Tool](https://kb.netgear.com/30267/RAIDiator-4-2-USB-Recovery-Tool),
which makes it look like a sanctioned way to boot external USB. It is not, for two
independent reasons:

1. **It is a firmware reflash, not a boot mechanism.** It writes a NETGEAR firmware image
   from a FAT-32 stick onto the internal module. It cannot boot a general-purpose OS and
   does not change boot order.
2. **The only image it would write is the wrong OS generation.** The chassis ran ReadyNASOS
   6.10.10 on **btrfs**; the tool flashes **RAIDiator 4.2.31**, the older line, which uses
   ext4/LVM and cannot read an OS6 btrfs volume. The OS6 recovery KB (29952) lists only the
   RN300/400/500 series, not the Ultra, so there is no OS6 recovery image for this chassis.

This is now moot - the array is Debian's, not ReadyNASOS's - but the tool would still be the
wrong instrument, and running it against a live data array would be a bad day.
