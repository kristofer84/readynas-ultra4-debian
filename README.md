# Debian 13 on a ReadyNAS Ultra 4

Installing Debian 13 (trixie) on a NETGEAR ReadyNAS Ultra 4 (RNDU4000) with the 7.3 TiB
data array left untouched. Recorded on 2026-09-08, from one machine, in the order it was
actually run.

The whole approach depends on one property of this hardware: the OS lives on its own 4 GB
`md0` raid1 across the same four disks, separate from the data array (`md127`, raid6,
btrfs, created 2019-07-31). Only `md0` is reformatted. The data array keeps its ReadyNASOS
mountpoint `/raid`, mounts read-write on a current kernel without conversion, and no client
had to change an fstab entry.

Nothing NETGEAR did to the storage is proprietary: md metadata 1.2, plain raid6, btrfs with
2013-era flags and no quotas. That was verified before any destructive step, which is why
the migration was safe to attempt.

The procedure was run on a unit on **ReadyNASOS 6.10.x**, whose data array is btrfs on `md127`;
that layout is what was proven portable. A unit still on RAIDiator 4.2.x is an ext4/LVM
generation and has not been tried. `docs/boot.md` and the boot module work are the same either
way.

## Read in this order

[**START-HERE.md**](START-HERE.md) is the guide for a first conversion by someone who can
copy a command but does not know what `md0` is: one path, no choices, every erasing step done by
a script that refuses rather than by you. [CHECKLIST.md](CHECKLIST.md) is the same thing for
someone who knows the words. The files below are the evidence and the why.

| file | what it answers |
|---|---|
| [docs/boot.md](docs/boot.md) | how the machine starts: no bootloader on the disks, a hidden 120 MB USB module, and the front Backup button as the BIOS boot override |
| [docs/rescue-stick.md](docs/rescue-stick.md) | building the headless grml stick that makes the rest possible |
| [docs/install.md](docs/install.md) | the procedure: prove the data, rebuild `md0`, `debootstrap`, configure, rewrite the boot module, first boot |
| [docs/gotchas.md](docs/gotchas.md) | what broke after the first boot, with symptoms |
| [`config/`](config/) | the files that ended up on the box, minus secrets |
| [`scripts/`](scripts/) | the four `/usr/local/sbin` scripts: `sync-boot-to-dom`, `backup-root`, `nas-fancontrol`, `md-event` |
| [`systemd/`](systemd/) | the local units, including the weekly root snapshot and the md stripe cache bump |
| [`hooks/`](hooks/) | the kernel and initramfs hooks that keep the boot module in step with `/boot` |
| [`install/`](install/) | the five scripts the guides call: `preflight.sh` (prove the data, take copies), `format-and-debootstrap.sh` (the only erasing step, guarded), `chroot-configure.sh`, `boot-module.sh`, `postinstall.sh` |
| [`build/`](build/) | `build-iso.sh` rebuilds the headless rescue ISO from a pinned upstream grml image; `verify-iso.sh` checks its structure |

Read `boot.md` before anything else. It explains why an ordinary "boot from USB and run the
installer" plan does not work here, and what the machine does instead.

## What you need

- The NAS, with a data array you have already proven readable and a backup of anything on it
  you cannot lose. The procedure reformats `md0` only, but it does rewrite the boot module.
- A 2 GB or larger USB stick for the rescue medium, and about 3 GB of scratch space on
  another Linux host to build it.
- A second machine on the same LAN. Nothing here is reachable from a console, so the install
  is driven over SSH.
- `xorriso`, `curl` and `debootstrap` on hosts that can reach a Debian mirror.
- Working hands on the front panel for the first boot. The first attempt on the recorded run
  needed an in-place fix 107 seconds in.

## Shape of the procedure

1. Boot a remastered grml from the Backup button, and prove the array reads (read-only,
   sha256 of a file written under ReadyNASOS).
2. `mkfs.ext4` on `md0` only, then `debootstrap trixie` onto it.
3. Configure the chroot: packages, `fstab` by UUID, networkd, `MODULES=dep` initramfs, the
   initramfs carrying mdadm and `mdadm.conf`.
4. Copy the kernel and initrd to the boot module and point the existing 2013 syslinux at
   them, leaving `LDLINUX.SYS` alone.
5. Boot it, with the Backup button within reach.
6. Install `sync-boot-to-dom` and both hooks, because from then on a kernel upgrade changes
   what boots.

A 120 MB module holding two kernels is the constraint that shapes steps 3, 4 and 6.

## What was verified on the recorded run

| check | result |
|---|---|
| boots unattended, no Backup button | yes, second boot 2026-09-08 13:40:44 |
| boot time | ~43 s (11.6 s kernel, 31.3 s userspace) |
| `md0` / `md1` / `md127` | `[4/4] [UUUU]` |
| data read under Debian | 120 MB file, sha256 matches the ReadyNASOS-era value |
| data read through the new NFS server | same sha256, read from the client host |
| data written | 64 MB over NFS, re-read on the NAS, sha256 matched |
| btrfs health | `btrfs device stats` zero on every counter |
| SMART | all four disks PASSED |

`install.md` closes with a section on what is verbatim from the machine's own logs and what
is reconstructed. The grml shell transcript did not survive: no `script -k`, no history.
Phases 3 to 6 there are consistent with the evidence but are not a transcript, and the page
says which parts are which.

## Not covered here

- Disk health and array integrity over time. That belongs to the hardware report for this
  particular set of four drives and is not part of a conversion.
- Cloud sync and the services built on top of the array. The units for those are in
  [`systemd/`](systemd/) only where they interact with the conversion (the root snapshot,
  the md stripe cache).
- Anything ReadyNASOS-specific beyond getting rid of it. Its users, groups, iSCSI target and
  AFP/FTP shares were not migrated, and `docs/gotchas.md` says what that leaves behind.

## The rescue image

`build/build-iso.sh` produces the headless grml image described in
[docs/rescue-stick.md](docs/rescue-stick.md). You can build it yourself, or take it from a
[release](https://github.com/kristofer84/readynas-ultra4-debian/releases): a tag `rescue-*` makes the workflow build the image in GitHub
Actions and attach it, so the asset is always one GitHub produced, never one uploaded by hand.
Every other run publishes only `SHA256SUMS`, `BUILD-INFO.txt` and the verification log.

Two checks on a downloaded asset, and they answer different questions:

```sh
gh attestation verify readynas-rescue-2026.09-amd64.iso --repo kristofer84/readynas-ultra4-debian
```

says GitHub built these bytes in this workflow, from this commit.

```sh
./build/build-iso.sh && cd dist && sha256sum -c SHA256SUMS
```

says the bytes follow from the pinned inputs. The build is reproducible: pinned upstream hash,
fixed `SOURCE_DATE_EPOCH`, pinned xorriso, root-normalised ownership. Five builds on
2026-11-26, aarch64 and x86_64, as root and as a normal user, produced one sha256.

The image ships the password `changeme` for root and the `grml` user, because a published
build cannot carry a real one. It is on the kernel command line, so it is visible to anyone
at the console, and it is usable by anyone on the same L2 segment while the stick is booted.
Set `SSH_PASSWORD` when you build your own. What it is for, and why that tradeoff is
acceptable for a stick you boot yourself, is in
[docs/rescue-stick.md](docs/rescue-stick.md#what-the-password-is-for).

## Licence

GPL-2.0. The scripts and units are meant to be copied, and contributions for other ReadyNAS
models are welcome if they come with the same kind of evidence.
