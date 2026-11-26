# Checklist

The operational version of this repository: seven steps and the gate that says whether to
continue. [docs/install.md](docs/install.md) is the same procedure with the
evidence and the timeline; read [docs/boot.md](docs/boot.md) once before you start, because
everything here depends on the machine having no bootloader on its disks and no console.

The four `install/*.sh` scripts have **not been run on a ReadyNAS**. They are the commands
recorded in `docs/install.md` with the hand transcription removed, which is where the mistakes
were going to come from. Treat the go/no-go they print as advisory and the data proof in step
3 as the actual gate.

## What you need

- The NAS, with whatever is on it backed up if you cannot lose it.
- A 2 GB USB stick with the rescue image: `gh release download rescue-2026.09 --repo
  kristofer84/readynas-ultra4-debian`, then `sha256sum -c SHA256SUMS` and `gh attestation
  verify readynas-rescue-2026.09-amd64.iso --repo …`. Or build it: `build/build-iso.sh`.
- A second Linux host on the same LAN, and ~2 GB of scratch space on it.
- `dd` for the stick, `scp`/`ssh` for getting the artefacts off the machine.

## 1. Drain the clients

Stop everything on the other hosts that writes to `/raid`: containers, sync clients, cron
dumps. Unmount the NFS exports there. Stop the sync clients first.

**Gate:** nothing but the NAS itself holds the array open.

## 2. Boot the rescue system

Power off. **Hold the front Backup button first**, then press Power, and keep holding through
POST, up to 15 s.

```sh
ssh root@<address>          # password: changeme, unless you built with SSH_PASSWORD
```

**Gate:** you get a shell. If not, fix the stick, do not improvise on the storage.

## 3. Prove the data and take the artefacts

```sh
# pick a file to hash, read-only, so nothing is written before the proof
mkdir -p /mnt/peek && mount -o ro /dev/md127 /mnt/peek
ls -lhS /mnt/peek/*/ | head -20 && umount /mnt/peek

./install/preflight.sh --data /dev/md127 \
    --hash-file /mnt/preflight-raid/other/<a file over 100 MB>
```

It checks every array is complete, reads the metadata, mounts the data array read-only, checks
the btrfs counters, hashes your file, then writes `boot-dom.img`, `readynasos-root.tar.gz` and
`readynas-share-configs.tar.gz` with a `SHA256SUMS`.

```sh
scp -r root@<address>:/root/preflight ./            # off the machine, now
cd preflight && sha256sum -c SHA256SUMS
```

**Gate: it says GO, and the three artefacts are on the other host with a verified
`SHA256SUMS`.** If the machine held data before this procedure, the hash it printed must match
the one you took earlier; on a unit with nothing to compare against, the point of the hash is
that it is recorded now. `--skip-root-tar` is for a unit with no configuration worth keeping.
The module image is never optional.

## 4. Rebuild the OS array only, and debootstrap

```sh
mkfs.ext4 -L debian-root /dev/md0
mount /dev/md0 /mnt/target
debootstrap trixie /mnt/target http://deb.debian.org/debian
mount --bind /dev /mnt/target/dev
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys
cp /etc/resolv.conf /mnt/target/etc/resolv.conf
```

**Gate:** `mkdir /mnt/target` was empty before `debootstrap`, and `mdadm --detail /dev/md0`
still shows the original creation date. `md1` and `md127` are untouched.

## 5. Configure the new root

```sh
git clone https://github.com/kristofer84/readynas-ultra4-debian \
    /mnt/target/root/readynas-ultra4-debian
chroot /mnt/target /root/readynas-ultra4-debian/install/chroot-configure.sh \
    --hostname nas --timezone Europe/Stockholm
```

Packages, `fstab` from `blkid` (with `space_cache=v2` up front), `mdadm.conf`, networkd and
the wait-online drop-in, `MODULES=dep`, initramfs, and the units enabled one at a time.

**Gate:** it prints `initrd … has ahci raid1 raid456 md-mod ext4 sd_mod mdadm` and `every
fstab UUID resolves`.

## 6. Point the boot module at the new kernel

```sh
./install/boot-module.sh --root /mnt/target
```

It finds the 120 MB FAT partition by size, keeps the outgoing pair as `VMLINUZ.OLD` /
`INITRD.OLD`, writes `VMLINUZ`, `INITRD.IMG` and a `SYSLINUX.CFG` with `prompt 0`, `timeout 30`
and the new root UUID, and lists anything else on the module that might still be bootable.
`LDLINUX.SYS` is never touched.

**Gate:** it prints the module contents, and no ReadyNASOS kernel/initrd pair is among them.

## 7. First boot, then the rest

`umount /mnt/target`, power off, and boot **with the Backup button within reach**: the first
boot stalls on `systemd-networkd-wait-online`, and sshd comes up anyway, which is the only
reason it is fixable in place.

Then, on the new system:

```sh
./install/postinstall.sh --repo /root/readynas-ultra4-debian
```

Scripts, units, hooks, `it87` and `drivetemp`, fan control, `md-event`, `backup-root.timer`.
It does **not** touch `/etc/exports` or `/etc/samba/smb.conf`; read
[the ported-exports note](docs/gotchas.md) before copying either from an old machine.

**Gate:** the verification table below, on a second boot with nobody watching.

## Verification

| check | expected |
|---|---|
| boots unattended, no button | yes, twice |
| `md0` / `md1` / `md127` | `[4/4] [UUUU]` |
| file read, sha256 vs the value from step 3 | matches |
| 64 MB written over NFS, re-read | hash matches |
| `btrfs device stats` on `/raid` | zero on every counter |
| SMART, all disks | PASSED |
| fan under load | ~1900 rpm at 40 °C, not 3340 |
| `systemctl --failed` | nothing |

## When it goes wrong

Recovery ladder, cheapest first: `docs/boot.md`. Copy `VMLINUZ.OLD` back over `VMLINUZ` from
the rescue system, then the weekly root snapshot, then the module image, then the archived
ReadyNASOS root. Every one of those was taken in step 3 or by `postinstall.sh`, so take them
seriously at the time.

## What not to do

Do not reformat anything but `md0`. Do not reinstall syslinux or touch `LDLINUX.SYS`. Do not
leave a ReadyNASOS kernel on the module. Do not run the NETGEAR USB Recovery Tool. Do not
expect PXE or a BIOS setup screen; both were tested and are not there.
