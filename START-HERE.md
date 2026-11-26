# Turning a ReadyNAS into a Debian NAS

This replaces the NAS's own operating system with Debian and keeps your files where they are.
You lose the old web admin interface, its users and its settings. Your files stay on their own
part of the disks and are not touched.

Written for someone who can open a terminal and copy a command, not for a Linux expert. If
something does not look like the "you should see" line, stop there and ask for help. Every step
that could cost you something says so.

## Two places you will type

Every command below says where it goes. There are only two places:

- **On your computer**, in a terminal on your Linux machine.
- **In the NAS window**, which is the `ssh root@IP` window you open in step 3. That shell is
  running on the NAS itself, from the rescue stick.

Keep the NAS window open from step 3 to step 6. If it closes, you lose nothing; reconnect with
`ssh root@IP` (password `changeme`) and `cd readynas-ultra4-debian` to get back to where you were.

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

**On your computer.**

```sh
sudo apt install gh
gh release download rescue-2026.09 --repo kristofer84/readynas-ultra4-debian
sha256sum -c SHA256SUMS
```

You should see `readynas-rescue-2026.09-amd64.iso: OK`. If it says FAILED, delete the file and
download it again; do not continue.

**On your computer.** Plug in the USB stick and find out what it is called:

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

**At the machine**, no computer involved.

1. Plug the stick into a **rear** USB port of the NAS.
2. Shut the NAS down: hold the power button until it goes off.
3. **Press and hold the front panel button marked Backup.** Keep holding it and press Power.
4. Keep holding Backup while the machine starts, about 15 seconds, then let go.

This button is how this hardware is told to start from a USB stick. Releasing it too early means
the NAS starts normally instead, and nothing is lost; just try again.

Wait two minutes.

## 3. Connect to it

**On your computer.** From here to step 6 you will be typing in the NAS window.

```sh
ping IP
ssh root@IP        # password: changeme
```

It asks whether to trust the machine the first time; type `yes`.

If `ping` says nothing at all, wait another minute and try once more. If it still says nothing,
power the NAS off and repeat step 2, holding Backup longer. If you cannot get in, stop here:
nothing on the NAS has been changed yet.

## 4. Look before you touch anything

**In the NAS window.**

```sh
git clone https://github.com/kristofer84/readynas-ultra4-debian
cd readynas-ultra4-debian
./install/preflight.sh --data /dev/md127 --hash-file auto
```

If the NAS is empty, with no files on it worth proving, use this instead of that last line:

```sh
./install/preflight.sh --data /dev/md127 --no-data
```

Either way it reads your data without changing it, proves a file still matches where there is one,
and saves copies of the old system's settings and start-up area into `/root/preflight`.

You should see `GO` on the last line. If it says `NO GO`, stop and send the whole output to
whoever is helping you: nothing has been erased and the NAS is still the machine it was.

Now copy those safety copies to your computer, so they survive even if the NAS does not. This is
the one block that runs **on your computer**, in a second terminal; the NAS window stays open and
untouched.

**On your computer:**

```sh
scp -r root@IP:/root/preflight .
```

Put that folder somewhere you will find it again, and keep it until the NAS has been running for a
month.

## 5. Install Debian

**In the NAS window.** This is the only step that erases anything, and it erases only the small
part of the disks where the NAS's own system lives, not where your files are.

```sh
./install/format-and-debootstrap.sh --preflight /root/preflight
```

It tells you exactly what it is about to erase and asks you to type a confirmation. Read that
line, then type it. If what it names surprises you, close the window instead; nothing has happened
yet.

Then it downloads and installs Debian. On this hardware that takes 15 to 25 minutes. Leave the
window open. If your connection drops, log in again with `ssh root@IP` and watch it continue:

```sh
tail -f /mnt/target/var/log/bootstrap.log
```

That path is the *new* system's log, which is why it starts with `/mnt/target`.

## 6. Configure it, and point the start-up at it

**In the NAS window.**

That command needs a way for you to log in afterwards. The simplest is to let it make a password:

```sh
chroot /mnt/target /root/readynas-ultra4-debian/install/chroot-configure.sh --hostname nas
```

At the end it prints `root can log in` and a password. **Write that password down now.** It is
stored nowhere you can read later, and it is the only way back into the machine.

If you already keep an SSH key and would rather use that, put your public key inside the new
system first, then ask for it by name. Your key has to be inside `/mnt/target/root/` for the
chroot to see it:

```sh
cp id_ed25519.pub /mnt/target/root/
chroot /mnt/target /root/readynas-ultra4-debian/install/chroot-configure.sh \
    --hostname nas --root-key /root/id_ed25519.pub
```

Then put the new system's start-up files on the small internal stick:

```sh
./install/boot-module.sh --root /mnt/target
```

It lists what it wrote and what else is on the stick. If it says `warn` about other files, stop
and send that list to whoever is helping; do not delete anything yourself.

## 7. Start it for the first time

**In the NAS window:**

```sh
poweroff
```

The window closes, which is normal. Wait for the machine to go off, then press the power button.
**Do not hold Backup this time.** Stay near the machine.

**On your computer**, until it answers:

```sh
ping IP
ssh root@IP
```

The first start is where anything that went unnoticed shows up, which is why you are standing
there. If it does not come up after three minutes, go to *If something goes wrong* below.

Then **in that new NAS window**:

```sh
cd /root/readynas-ultra4-debian
./install/postinstall.sh
```

It installs the housekeeping that keeps the machine healthy: fan control, a weekly copy of the
system, and a check that tells you if a disk array is unhappy.

## 8. Check that it worked

**In the NAS window.**

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
