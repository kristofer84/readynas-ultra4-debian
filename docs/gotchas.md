# What bit after the first boot

Every item below cost time on the recorded run. None of them announce themselves, and each
was found the slow way, so they are written out with the symptom as well as the fix.

## `it87` is never autoloaded

Super-I/O chips are not bus-enumerated, so the module has no modalias and nothing loads it.
Without it there is no `it8721` hwmon, `/usr/local/sbin/nas-fancontrol` runs but silently
finds nothing every cycle, and the fan sits at full speed. The service still reports
`active`, which is what makes this expensive to notice.

Covered twice on purpose, so it does not depend on module-load ordering:

```
# /etc/modules-load.d/it87.conf
it87
```

```
# /etc/systemd/system/nas-fancontrol.service.d/modprobe.conf
[Service]
ExecStartPre=-/sbin/modprobe it87
```

`drivetemp` needs the same treatment for the disk temperatures `nas-fancontrol` reads; it is
a module, not a package.

## `systemd-networkd-wait-online` hangs the boot

A `Name=en*` match covers the second NIC, which has no cable, and wait-online requires
*every* managed link by default. That blocks `network-online.target`, and with it `nfs-server`,
`smbd` and `multi-user.target`, for the full 120 s default if nothing intervenes.

Symptom: services stuck in `start waiting`, and `systemctl list-jobs` showing
`systemd-networkd-wait-online.service … running`.

Fix, a drop-in passing `--any --timeout=30` ([`../config/`](../config/)):

```
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=30
```

**sshd is ordered on `network.target`, not `network-online.target`**, so on the recorded run
it was serving 25 s into the boot while wait-online was blocked. The drop-in went in at 107 s
and the boot completed immediately after. That sshd ordering is the only reason a machine
with no console was fixed in place instead of needing the Backup button again. Do not count
on it: do the first boot where you can hold the button.

## `systemd-resolved` is a separate package in trixie

Enabling it before installing it fails the entire `systemctl enable` call, including the
arguments that were valid, and prints one error that is easy to scroll past. The machine then
boots with no network at all. Enable units one at a time.

## The ported `exports` carried an old grant with it

`/etc/exports` was rewritten from the ReadyNASOS one, and one line came across unchanged:
`/raid/home *(rw,...)`, the empty ReadyNAS admin home, exported read-write to any host on the
network. Nothing mounted it and nothing referenced it; it had always been there. Removed on
2026-09-09.

Read a ported config for what it *grants*, not only for the lines you need from it.

## The ReadyNASOS kernel must not stay bootable on the module

Its initrd contains `"No partitions found on any disk! Going to factory default..."`, and md0
no longer holds ReadyNASOS. Deleting it from the module is deliberate. Leaving it there as a
"fallback" is a loaded gun pointed at the data array.

The supported fallback is the `VMLINUZ.OLD` / `INITRD.OLD` pair that
[`../scripts/sync-boot-to-dom`](../scripts/sync-boot-to-dom) maintains, plus the saved image
of the module.

## `/` is 3.9 GB, and it fills

Root is `md0`, a 4 GB raid1 across all four disks, and nothing of the data array lives on it.
On 2026-11-17 it was at 64 % (1.4 GB free): a spare kernel (108 MB of modules plus 25 MB of
`/boot`), 153 MB of `/var/cache/apt`, 315 MB of journald. Each Debian point release installs
a new `linux-image-*` and nothing removes the previous one, so four had accumulated,
including three `rc` leftovers whose module trees still sat in `/usr/lib/modules/`.

```sh
uname -r && ls /usr/lib/modules/          # keep the running one
apt-get purge linux-image-<old-version>
apt-get clean && journalctl --vacuum-size=100M
df -h /
```

Purged together that day: 2.5 GB used to 1.9 GB, 50 %, 2.0 GB free. There is no way to grow
this array without opening the case, so treat it as fixed.

## btrfs `space_cache=v1` is what the array mounts with first

The kernel warns it is deprecated. Convert to v2 and pin it in `/etc/fstab`. It is not a live
change: the kernel would not build the free-space tree on a plain `remount`, and the array
had to go read-only and back to read-write, which means stopping everything holding `/raid`
open. Plan it for a quiet moment, not mid-sync.

## The old ReadyNAS leftovers on the data array

`/raid` is mounted, not reformatted, so everything ReadyNASOS put there comes across:
`.apps`, `._share`, `home`, `.purge`, `.vault`, `.timemachine`, `.snapshots`.

Two things bite when removing them:

- **`home` contains a nested subvolume** (`home/admin`). `btrfs subvolume delete` refuses a
  subvolume that still contains one, so the inner goes first.
- **`.apps/DO_NOT_DELETE` is mode `dr-xr-xr-x`** and `.apps/docker-cli-rnapp` is
  `drwx--x--x`. A plain `rm -rf` trips on both. `btrfs subvolume delete` ignores directory
  permissions, which is the right tool anyway.

Subvolume deletion is asynchronous: `df` does not move at the moment you run it. Watch it
rather than concluding the delete failed.

`._share` is the only one worth archiving first, because it records how each share was set
up (`samba.conf`, `nfs.conf`, `afp.conf`, `ftp.conf`). Here it was 43 files, 1.7 KiB
compressed.

## uids and ACLs from ReadyNASOS stay on the data

The old shares are mode 0777 with uids 98 and 99 and POSIX ACLs (the `+` in `ls -l`). A
single local user works only because of the 0777. Anything that tightens the mode breaks
access to data whose ownership no longer maps to anything. Worth a `chown` pass if the
permissions are ever cleaned up.

## `md1` and `md127` show `auto-read-only` / `read-auto`

Normal md behaviour until the array's first write, not a misconfiguration. `/proc/mdstat`
shows `[4/4] [UUUU]` and `mdadm --detail` shows a creation date in 2019 either way.

## The front LCD goes dark

`nv6lcd` was a NETGEAR module. Nothing drives the panel under Debian, so it shows nothing
during boot. Cosmetic.
