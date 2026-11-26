# Installing Debian 13 on the ReadyNAS Ultra 4

On **2026-09-08** this ReadyNAS Ultra 4 went from ReadyNASOS 6.10.10 to Debian 13
(trixie), with the 7.3 TiB data array never reformatted. This is that procedure, in the
order it was actually run. Addresses, hostnames and mount paths are placeholders - use
your own.

Read [boot.md](boot.md) first. It explains the one thing that makes this machine different
from any other PC: **there is no bootloader on the disks**, the BIOS prefers a hidden
internal USB module, and the only way to boot anything else is the front-panel Backup
button. Everything below assumes that is already understood.

The shape of it: boot a remastered **grml** from that button, prove the data reads, reformat
only the 4 GB OS array, **`debootstrap`** a new root onto it, configure it in a chroot, then
put the new kernel on the module and point syslinux at it - keeping the 2013 bootloader
binary untouched.

| | |
|---|---|
| debootstrap started | 2026-09-08 11:07:50 |
| Debian first booted | 2026-09-08 13:31:37 |
| Kernel | `6.12.107+deb13-amd64` |
| Root | `md0`, ext4, label `debian-root` |
| Served data | `md127`, btrfs, untouched since 2019-07-31 |

## Why debootstrap and not the installer ISO

A `debian-13.6.0-amd64-netinst.iso` was downloaded and staged anyway (it is still in the
backup set), but it was never used:

- **GRUB cannot be installed here.** The disks are GPT and partition 1 starts at sector 64,
  so there is nowhere to put a BIOS Boot Partition - see [boot.md](boot.md).
- **The netinst ISO cannot be booted without a bootloader on the disk.** The BIOS will boot
  the internal module, or external media with the Backup button, and nothing else. So the
  installer would still have to be run from grml, at which point `debootstrap` is the same
  thing with fewer moving parts.

`debootstrap` also leaves the existing syslinux on the module usable, which is the whole
trick: the bootloader stays, only the two files it loads get replaced.

## Phase 0 - drain the clients

The array cannot be reformatted while something is writing to it. On this network that
means the client host, which in this case held it open in four places:

| consumer | why it matters |
|---|---|
| a photo-library container | its library plus four cloud-sync trees on the array |
| an application that dumps its database | weekly `pg_dump` written to `/raid/other` |
| two cloud sync clients | live bidirectional sync into the same array |

The whole list was stopped first; the client host itself stayed up, because nothing else
depended on the NAS. Stop the sync clients **before** anything else, or they will be
mid-write when the array goes away and will spend the rest of the day re-uploading.

NAS-side, nothing needed stopping: ReadyNASOS's own NFS/SMB/iSCSI were about to be replaced
by the reboot.

## Phase 1 - boot grml and get an address

The stick is prepared in [rescue-stick.md](rescue-stick.md): remastered so it is reachable
headless, with `scripts/grml.sh` doing DHCP, because stock grml never configures networking
on its own. Procedure:

1. Power off.
2. **Hold the front Backup button first**, then press Power, and keep holding through POST
   (up to 15 s). Releasing early is the same as not pressing it.
3. Wait for the page from [`grml.sh`](../rescue/grml.sh), then `ssh` in with the password
   set on the GRUB command line - see [rescue-stick.md](rescue-stick.md).

If that does not work, stop here and fix the boot stick - do not start improvising on the
machine's own storage.

## Phase 2 - prove the data before writing anything

The go/no-go. All of this is read-only.

```sh
cat /proc/mdstat                     # md0 md1 md127, all [4/4] [UUUU]
mdadm --detail /dev/md127            # metadata 1.2, raid6, created 2019-07-31
mount -o ro /dev/md127 /mnt/raid
btrfs subvolume list /mnt/raid | wc -l    # 15
btrfs device stats /mnt/raid              # all zero
sha256sum /mnt/raid/<a 120 MB file>       # must match the ReadyNASOS-era value
umount /mnt/raid
```

The sha256 comparison is the part that matters. Everything else says the array *assembled*;
re-reading a file that was written under ReadyNASOS and getting the same hash says the data
is intact, and that the migration is safe to start.

## Phase 3 - rebuild the OS array

Only `md0` (partition 1 of each disk, 4 GB, raid1) is touched. `md1` stays as swap and
`md127` stays as data; both are the 2019 arrays and neither is recreated.

```sh
mkfs.ext4 -L debian-root /dev/md0
mount /dev/md0 /mnt/target
```

Proof that this is what happened, rather than a rebuilt array: `mdadm --detail /dev/md0`
still reports **Creation Time Wed Jul 31 16:18:56 2019**, and the ext4 UUID
`abd6582f-598a-4d16-bb32-e287cb985c5b` is the one in `/etc/fstab` and on the syslinux
command line.

**That UUID is now load-bearing.** There is no operator at this machine's console. A typo in
`root=UUID=` produces a kernel panic nobody can see, recoverable only with the Backup button
and the grml stick.

## Phase 4 - debootstrap

```sh
debootstrap trixie /mnt/target http://deb.debian.org/debian
```

- suite, target path and mirror are all proven by the log (below).
- default package set, **not** `--variant=minbase`: the observed base system includes
  `cron`, `dmidecode`, `ifupdown`, `whiptail` and `systemd`, which minbase does not carry.
- `main` only: the log fetches exactly one suite index, `dists/trixie/main`.

The log is the best artefact this migration produced, and it survived:
`/var/log/bootstrap.log` on the NAS, 81 KB. It starts at 11:07:50 with the `InRelease` fetch
into `/mnt/target/var/lib/apt/lists/`, downloads through 11:10:12 (150 fetches), and ends
after 155 `Setting up` lines with no errors. The working directory `/debootstrap` was
deleted afterwards; the copy of its log at `/var/log/bootstrap.log` is the only reason any
of this is recoverable.

## Phase 5 - configure the chroot

Ordering below is the order the filesystem recorded, not a tidied-up version.

```sh
mount --bind /dev  /mnt/target/dev
mount --bind /proc /mnt/target/proc
mount --bind /sys  /mnt/target/sys
cp /etc/resolv.conf /mnt/target/etc/resolv.conf    # apt needs DNS inside the chroot
chroot /mnt/target
```

Packages, verbatim from `/var/log/apt/history.log` (11:19-11:26):

```sh
apt-get install -y -qq initramfs-tools
apt-get install -y -qq linux-image-amd64 mdadm btrfs-progs openssh-server sudo \
    nfs-kernel-server samba smartmontools systemd-timesyncd ifupdown \
    isc-dhcp-client vim less htop ethtool usbutils pciutils rsync ca-certificates
apt-get install -y -qq systemd-resolved
```

`initramfs-tools` went in as its own transaction immediately before the kernel, so the
kernel's postinst has something to call.

`sources.list` was written at 13:19, with `contrib` and `non-free-firmware` added to all
three lines. Identity and console access came next: `/etc/hostname` = `nas`,
`127.0.1.1 nas` in `/etc/hosts`, a root password (kept off the NAS, in whatever password
store you already use), and `/etc/network/interfaces` at 13:18 - which is stock today,
because ifupdown arrived with debootstrap and the network was then moved to
systemd-networkd at 13:25.

`/etc/fstab`, addressing everything by UUID so device renumbering cannot break it:

```
UUID=abd6582f-…  /       ext4    errors=remount-ro,noatime   0 1
UUID=1e174eec-…  none    swap    sw                          0 0
UUID=a6cae93c-…  /raid   btrfs   defaults,noatime            0 0
```

`space_cache=v2` was appended to the `/raid` line later the same evening; the backup beside
it is `/etc/fstab.bak-v2-230555`, which dates that edit to 23:05:55.

Networking, `systemd-networkd` with a wildcard match so interface renaming cannot strand a
headless box:

```
# /etc/systemd/network/10-wired.network
[Match]
Name=en*

[Network]
DHCP=yes
```

```
# /etc/systemd/network/20-enp2s0-optional.network
[Match]
Name=enp2s0

[Link]
RequiredForOnline=no

[Network]
DHCP=yes
```

Enable units **one at a time**:

```sh
systemctl enable systemd-networkd
systemctl enable systemd-resolved
```

This is not style. `systemd-resolved` is a separate package in trixie, and enabling it
before installing it fails the entire `systemctl enable` call - including the networkd
argument that was valid - and prints one error that is easy to scroll past. The machine then
boots with no network at all.

Initramfs, on a 120 MB module that has to hold a working pair plus a fallback:

```
# /etc/initramfs-tools/initramfs.conf
MODULES=dep
```

That is what produces a 12.9 MB initrd instead of the default `MODULES=most` at ~56 MB. Set
it, then regenerate and check the contents actually include the pieces needed to reach md0:

```sh
update-initramfs -u
lsinitramfs /boot/initrd.img-* | grep -E 'ahci|raid1|raid456|md-mod|ext4|sd_mod|mdadm'
```

`mdadm.conf` must exist before that regeneration, or the initramfs has nothing to assemble
with. Generate it from the running arrays and keep `HOMEHOST <ignore>`:

```sh
mdadm --detail --scan
```

The `rootfstype=ext4` on the syslinux line matters as much as the UUID: without it the
initramfs guesses.

## Phase 6 - put the kernel on the module

The module is a 120 MB FAT16 partition. Address it **by-id** - `sdX` names shift between
boots, and a wrong target here is unrecoverable:

```sh
# find the module's own name first: ls -l /dev/disk/by-id | grep -i usb
DOM=/dev/disk/by-id/usb-SMI_USB_DISK_<SERIAL>-0:0-part1
mkdir -p /mnt/dom && mount "$DOM" /mnt/dom
cp /mnt/target/boot/vmlinuz-6.12.107+deb13-amd64   /mnt/dom/VMLINUZ
cp /mnt/target/boot/initrd.img-6.12.107+deb13-amd64 /mnt/dom/INITRD.IMG
```

Then rewrite `SYSLINUX.CFG`. This is the file as it stands on the module, written 13:28:

```
serial 0 9600
default debian
prompt 0
timeout 30

label debian
  kernel VMLINUZ
  append initrd=INITRD.IMG root=UUID=abd6582f-598a-4d16-bb32-e287cb985c5b ro rootfstype=ext4 console=tty0 console=ttyS0,115200n8

label memtest
  kernel MEMTEST
```

Four things about that file:

- **`LDLINUX.SYS` is not touched.** It is the 2013 syslinux binary (`Jan 5 2013` still), and
  it is found by the boot sector at a fixed location. Replacing the config and the two
  payload files is the lowest-risk change that works: FAT does not relocate existing files.
- **`prompt 0` and `timeout 30`** because it has to boot unattended. A menu is useless where
  nothing can select from it.
- **`root=UUID=`** must be the reformatted filesystem's UUID. See Phase 3.
- **`console=ttyS0`** buys nothing today - the serial header is internal - but it costs
  nothing and is the only diagnostic route if the case is ever opened.

The ReadyNASOS kernel and initrd were **deleted from the module on purpose**, not kept as a
fallback. Its initrd contains `"No partitions found on any disk! Going to factory
default..."`, and md0 no longer holds ReadyNASOS; leaving it bootable would be a loaded gun
pointed at the data array. The supported fallback is the `VMLINUZ.OLD` / `INITRD.OLD` pair
`sync-boot-to-dom` maintains (Phase 8), plus the byte-verified module image.

`/mnt/dom` is a leftover from this step; `sync-boot-to-dom` mounts the module at
`/run/dom-sync` instead and keeps its own budget checks.

## Phase 7 - first boot

13:31:37. The journal records the whole first boot, and it is worth reading before trusting
the box:

```
Command line: initrd=INITRD.IMG root=UUID=abd6582f-... ro rootfstype=ext4
              console=tty0 console=ttyS0,115200n8 BOOT_IMAGE=vmlinuz
```

It booted, but `systemd-networkd-wait-online` started at 13:31:43 and did not finish. The
default behaviour waits for **every** managed link, `Name=en*` covers the uncabled second
port, and `network-online.target` therefore blocked `nfs-server`, `smbd` and
`multi-user.target` with it.

**sshd came up anyway, at 13:32:02** - it orders on `network.target`, not
`network-online.target`. That is the difference between a box that can be fixed over the
network and one that needs a console it does not have. The fix was applied in place 107
seconds into the boot:

```
# /etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=30
```

After `daemon-reload` and a restart: wait-online finished 13:33:28, `multi-user.target`
13:33:33, with nfs-server and smbd right behind. Then a **clean reboot at 13:39:50** to
prove it works with nobody watching; the second boot started 13:40:44 and is still the
running one as of 2026-10-17. The journal holds exactly two boots.

Then verify, before believing any of it:

| check | result |
|---|---|
| boots unattended, no Backup button | yes |
| md0/md1/md127 `[4/4] [UUUU]` | yes |
| NIC | `sky2` v1.30 on `enp1s0` |
| data read under Debian | 120 MB file, sha256 matches ReadyNASOS |
| data read **through the new NFS server** | same sha256, read from the client host |
| data written | 64 MB from the client host over NFS, re-read on the NAS, sha256 matched |
| btrfs health | `btrfs device stats` - zero on every counter |
| SMART | all four disks PASSED |

## Phase 8 - what the install still owed

Within the first day, and each for a reason:

| when | what | why |
|---|---|---|
| 13:36 | `lm-sensors`, `fancontrol` | the `it87` driver refuses the chip's automatic mode, so the fan sat at `pwm1=255`, ~3340 rpm, with disks at 34-36 °C |
| 13:43 | a third-party apt source (`onedrive.sources`) | the cloud sync client is not in trixie main |
| 14:52 | `sync-boot-to-dom` + both hooks | a kernel upgrade now changes **what boots**; without it the module keeps an old kernel whose modules are gone |
| 20:05 | `/root/.ssh/authorized_keys` | password login for root was never the plan |
| 23:05 | `space_cache=v2` in `/etc/fstab` | the array had mounted with the deprecated v1 |
| Sep 9 07:32 | `backup-root` + weekly timer | first snapshot of the new root, to a different array |

Two follow-ups are not part of the install but were forced by it: Samba and the NFS exports
were rebuilt from scratch (nothing in the ReadyNASOS files was usable - see
[gotchas.md](gotchas.md) for what porting them would have carried across), and the
ReadyNASOS root was archived before md0 was touched
(`md0-readynasos-root-20260908.tar.gz`, 366 MB, 16 654 entries).

## The timeline the machine recorded

NAS filesystem times are the machine's own; the ReadyNASOS archive and the password files
kept off the NAS carry **copy** times, not creation times, and are not used here.

| time | event | where it shows |
|---|---|---|
| 11:07:50 | debootstrap starts, first `InRelease` fetched | `bootstrap.log` |
| 11:10:12 | last package downloaded | `bootstrap.log` |
| 11:19:55 | `initramfs-tools` | `apt/history.log.1.gz` |
| 11:20:16 | kernel, mdadm, btrfs-progs, ssh, nfs, samba | same |
| 11:26:20 | `systemd-resolved` | same |
| 13:13:23 | `/etc/machine-id` | mtime |
| 13:18:37 | `/etc/network/interfaces` | mtime |
| 13:18:42 | `bootstrap.log` preserved in `/var/log` | mtime |
| 13:19 | hostname, root password, `sources.list` | mtime |
| 13:20:01 | `MODULES=dep` | `initramfs.conf` mtime |
| 13:23:04 | `/etc/default/mdadm` | mtime |
| 13:25:39 | `10-wired.network` | mtime |
| 13:28 | `SYSLINUX.CFG` on the module | mtime |
| 13:31:37 | **first Debian boot** | `journalctl --list-boots` |
| 13:32:02 | sshd up, network-online still waiting | boot -1 journal |
| 13:33:24 | wait-online drop-in written | mtime + journal |
| 13:33:33 | `multi-user.target` | journal |
| 13:39:50 | clean shutdown; 13:40:44 second boot | journal |
| 23:05:55 | `space_cache=v2` | `fstab.bak-v2-230555` |

## What is proven, and what is reconstructed

This was done by hand in a grml shell. **No transcript of it survives** - the grml session's
history died with its tmpfs, and the Claude session ids in the commit trailers have no
matching transcript in any log collected from the machines involved. Everything above was
rebuilt from the machine's own logs and file timestamps, so it is worth being explicit about
the difference:

**Verbatim, from the system:**

- the apt transactions (`/var/log/apt/history.log.1.gz`) and the debootstrap log, including
  its 155 `Setting up` lines (`/var/log/bootstrap.log`)
- `SYSLINUX.CFG`, both `.network` files, `any.conf`, `fstab`, `sources.list`
- the first-boot journal, the boot times, and the 104-second wait-online stall
- every file mtime in the timeline

**Reconstructed, consistent with the evidence but not quoted:**

- the `debootstrap` invocation. The suite, target path, mirror and component are proven by
  the log; the presence or absence of `--verbose` / `--arch` is not.
- `mkfs.ext4 -L debian-root /dev/md0`. The `debian-root` label and the ext4 UUID are proven;
  the exact `mkfs` flags are not.
- the copy commands in Phase 6 and their mountpoint. The result is proven; the grml-side
  device name is not, and cannot be recovered.

None of that is a reason to trust the doc less, but it is a reason not to treat Phase 3-6 as
a transcript. If it is ever repeated, take the thirty seconds to `script -k` the grml
session to a file on a writable USB stick, and the next version of this page can be exact.

## If you do this again

- **The order is not negotiable:** data verified read-only → mkfs only md0 → debootstrap →
  config → module → boot. Every step that could lose the array is preceded by a read-only
  check of the array.
- **Do not "improve" the module.** Keep `LDLINUX.SYS`, keep the file names `VMLINUZ` and
  `INITRD.IMG`, keep a `VMLINUZ.OLD` pair, and never leave a bootable ReadyNASOS initrd on
  it.
- **Kernel upgrades go through `sync-boot-to-dom`.** It is wired into
  `/etc/kernel/postinst.d/` and `/etc/initramfs/post-update.d/`; a hand `update-initramfs`
  without it leaves the module booting a kernel it can no longer load modules for.
- **Do the first boot somewhere you can hold the Backup button.** The first attempt needed
  a fix 107 seconds in. That it was reachable over ssh is luck plus `After=network.target`,
  not a design.
- Expect the tools to be slower than they look: this is a 2010 Atom. `update-initramfs` and
  a 366 MB tar of the old root are the slow parts, not the network.

Related: [boot.md](boot.md) for the boot chain and recovery, [rescue-stick.md](rescue-stick.md)
for building the headless grml stick, [gotchas.md](gotchas.md) for what bit after the first
boot, and [`../config/`](../config/) for the files that ended up on the box.
