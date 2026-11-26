# Turning a ReadyNAS into a Debian NAS

This replaces the NAS's own operating system with Debian and keeps your files where they are.
You lose the old web admin interface, its users and its settings. Your files stay on their own
part of the disks and are not touched.

Written for someone who can open a terminal and copy a command, not for a Linux expert. If
something does not look like the "you should see" line, stop there and ask for help. Every step
that could cost you something says so.

**Before you start:** if the files on the NAS matter and exist nowhere else, copy them off first.
This procedure is built to keep your files, but a copy is the only thing that saves you from a
wrong command.

## You need

- A Linux computer on the same network, where you can open a terminal.
- One USB stick, 2 GB or larger. **It will be erased.**
- The NAS's IP address, for example `192.168.1.10`. Your router's list of connected devices
  shows it. Everything below calls it `IP`.
- Two or three hours, and you should be near the machine for the first start.
- About 3 GB free disk space on your computer for copies of the old system.

## 1. Make the rescue stick

On your Linux computer, in a terminal:

```sh
sudo apt install gh
gh release download rescue-2026.09 --repo kristofer84/readynas-ultra4-debian
sha256sum -c SHA256SUMS
```

You should see `readynas-rescue-2026.09-amd64.iso: OK`. If it says FAILED, delete the file and
download it again; do not continue.

Plug in the USB stick and find out what it is called:

```sh
lsblk
```

Look for a device whose size is your stick, for example `sdb` with `7.5G`. Ignore everything
else: on a laptop `/dev/nvme0n1` and `/dev/sda` are your own disks. If you are unsure, unplug the
stick, run `lsblk` again, and the one that disappeared is the stick.

```sh
sudo dd if=readynas-rescue-2026.09-amd64.iso of=/dev/sdb bs=4M status=progress conv=fsync
```

Replace `sdb` with your stick. **This erases that device**, so the next letters must be your
stick and nothing else. It takes a few minutes and prints progress. When it finishes:

```sh
sync
```

## 2. Start the NAS from the stick

1. Plug the stick into a **rear** USB port of the NAS.
2. Shut the NAS down: hold the power button until it goes off.
3. **Press and hold the front panel button marked Backup.** Keep holding it and press Power.
4. Keep holding Backup while the machine starts, about 15 seconds, then let go.

This button is how this hardware is told to start from a USB stick. Releasing it too early means
the NAS starts normally instead, and nothing is lost; just try again.

Wait two minutes.

## 3. Connect to it

```sh
ping IP
ssh root@IP        # password: changeme
```

It asks whether to trust the machine the first time; type `yes`.

If `ping` says nothing at all, wait another minute and try once more. If it still says nothing,
power the NAS off and repeat step 2, holding Backup longer. If you cannot get in, stop here:
nothing on the NAS has been changed yet.

## 4. Look before you touch anything

```sh
git clone https://github.com/kristofer84/readynas-ultra4-debian
cd readynas-ultra4-debian
./install/preflight.sh --data /dev/md127 --hash-file auto
```

It reads your data without changing it, proves a file still matches, and saves copies of the old
system's settings and start-up area into `/root/preflight`.

You should see `GO` on the last line. If it says `NO GO`, stop and send the whole output to
whoever is helping you: nothing has been erased and the NAS is still the machine it was.

Copy those safety copies to your computer, then put them somewhere you will find them again:

```sh
# this runs on your computer, not on the NAS
scp -r root@IP:/root/preflight .
```

If the NAS is empty and there is nothing on it to prove, use this instead of the first command:

```sh
./install/preflight.sh --data /dev/md127 --no-data
```

## 5. Install Debian

This is the only step that erases anything. It only erases the small part of the disks where the
NAS's own system lives, not where your files are.

```sh
./install/format-and-debootstrap.sh --preflight /root/preflight
```

It tells you exactly what it is about to erase and asks you to type a confirmation. Read that
line, then type it. If what it names surprises you, close the window instead; nothing has happened
yet.

Then it downloads and installs Debian. On this hardware that takes 15 to 25 minutes. Leave the
window open. If your connection drops, log in again and watch:

```sh
tail -f /var/log/bootstrap.log
```

## 6. Configure it, and point the start-up at it

```sh
chroot /mnt/target /root/readynas-ultra4-debian/install/chroot-configure.sh --hostname nas
```

At the end it prints either `root can log in` or a password. **If it prints a password, write it
down now.** It is stored nowhere you can read later, and it is the only way back in.

If you have an SSH key and would rather log in with that, add `--root-key /root/id_ed25519.pub`
to the command. Either way, one of the two is needed.

Then put the new system's start-up files on the small internal stick:

```sh
./install/boot-module.sh --root /mnt/target
```

It lists what it wrote and what else is on the stick. If it says `warn` about other files, stop
and send that list to whoever is helping; do not delete anything yourself.

## 7. Start it for the first time

```sh
poweroff
```

Wait for it to go off, then press the power button. **Do not hold Backup this time.** Stay near
the machine until it answers:

```sh
ping IP
ssh root@IP
```

The first start is where anything that went unnoticed shows up, which is why you are standing
there. If it does not come up after three minutes, go to *If something goes wrong* below.

When you are in:

```sh
cd /root/readynas-ultra4-debian
./install/postinstall.sh
```

It installs the housekeeping that keeps the machine healthy: fan control, a weekly copy of the
system, and a check that tells you if a disk array is unhappy.

## 8. Check that it worked

| do this | you should see |
|---|---|
| `uname -r` | a version starting with `6.12` |
| `cat /proc/mdstat` | three arrays, each with `[4/4] [UUUU]`, no `_` |
| `df -h /raid` | your data, with the same amount used as before |
| listen to the NAS | the fan is quiet, not roaring |
| reboot once with `reboot`, then log in again | it comes up on its own, no button |

Your files are on `/raid` and are readable. **Sharing them again is a separate job**: the
repository has an example Samba configuration in `config/smb.conf` and an example NFS one in
`config/exports`, and someone technical should set those up for your network and users. The files
themselves are already there in the meantime.

## If something goes wrong

- **Before step 5**: nothing has been erased. Start over from step 2, or just switch the NAS off
  and use it as it was.
- **After step 5**: your files are still on a different part of the disks and were not part of
  what was erased. The way back is the copies you made in step 4, and
  [docs/boot.md](docs/boot.md) lists the recovery options in order of how much they cost. Get help
  before trying them; the one thing to avoid is doing something to the disks by hand.
- **Never** run the NETGEAR "USB Recovery Tool". It writes to the internal start-up area and is
  not a way back from this.

## Words you will see

| word | what it means here |
|---|---|
| `md0` | the small area, about 4 GB, where the NAS's own system lives. This is what gets replaced |
| `md127` | the large area where your files live. Never touched by this procedure |
| `chroot` | a way to set up a system while it is not running yet |
| the boot module | a small 120 MB stick inside the NAS that starts it. Its only copy of the start-up files is what step 6 updates |
| `initrd` | the small helper system the kernel loads first, to find your disks |

[CHECKLIST.md](CHECKLIST.md) is the same procedure written for someone who knows the words.
