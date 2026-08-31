# Restore this Omarchy identity with Omaclone

You are on a **new** disk or computer. Omarchy is already installed. This file lives next to the encrypted restic repo (or with the plugin) and has **no passwords**.

The clone is an **overlay** of `$HOME`, not a wipe. ssh, gpg, browsers, and desktop keyring files come back. Extra files already on this home stay unless you pass `--delete` and type `REPLACE`.

## 1. Network (skip for a local disk)

Plug in Ethernet (or join Wi-Fi) if the clone is on a NAS or in the cloud.

## 2. Reach the clone

The kit is `$mount/omaclone/` (`restore`, `config.toml`, `SHA256SUMS`, restic `repo/`).

**USB / extra disk** — plug it in. If it does not automount:

```bash
lsblk
sudo mkdir -p /mnt/omaclone
sudo mount /dev/disk/by-uuid/UUID /mnt/omaclone
ls /mnt/omaclone/omaclone
```

**NFS:**

```bash
sudo pacman -S --needed nfs-utils
sudo mkdir -p /mnt/omaclone
sudo mount -t nfs4 HOST:/EXPORT /mnt/omaclone
ls /mnt/omaclone/omaclone
```

If `ls` shows an owner other than your uid (usually 1000), NFS squash is wrong — see the README NFS section.

**SMB:** use a credentials file (mode 600), not `password=` on the command line:

```bash
sudo pacman -S --needed cifs-utils
sudo mkdir -p /mnt/omaclone
install -m 600 /dev/null /dev/shm/omaclone.smb
printf 'username=%s\npassword=YOUR_SMB_PASSWORD\n' "$USER" > /dev/shm/omaclone.smb
sudo mount -t cifs //HOST/SHARE /mnt/omaclone -o credentials=/dev/shm/omaclone.smb,uid=$(id -u),gid=$(id -g),vers=3.0,nosuid,nodev,noexec
shred -u /dev/shm/omaclone.smb
```

**SFTP:** key-only. First connection needs `known_hosts` (`ssh user@host` once). The kit sits in the remote directory next to `repo/` (default `omaclone/`).

**S3:** no `./restore` on the bucket. Install the plugin (step 3) and re-enter access keys. They are not on the recovery card.

Replace `HOST:/EXPORT`, `//HOST/SHARE`, or `UUID` with the locator from `~/.local/share/omaclone/RECOVERY.md` (also in `config.toml` on a share).

## 3. Run the TUI

From a share or disk that has the bootstrap copy:

```bash
/mnt/omaclone/omaclone/restore
```

Prefer a plugin install from git. The kit checks `SHA256SUMS`; a mismatch asks you to type `UNTRUSTED`.

From the plugin on a blank Omarchy box (cloud, or you installed the plugin):

```bash
omarchy plugin add https://github.com/FortyTwoFifty/Omaclone.git --enable
~/.config/omarchy/plugins/omaclone.plugin/scripts/omaclone restore
```

It installs `restic`, `jq`, `gum`, and `rsync` if needed, then asks for the restic password:

- Proton Pass / 1Password / keyring if that is how this repo was created
- Or paste the password once (it is not saved, not logged)

On a new PC the local keyring is empty — paste or sign in to the password manager.

Pick a snapshot (hostname + time). Type `RESTORE` to overlay `$HOME`. `--same-machine` is for a replaced boot drive on this PC; it can install hardware packages and still refuses LUKS/bootloader files.

If the username on this box is different, restore remaps a single home from the snapshot onto `$HOME`. Several homes in one snapshot cannot be guessed.

## 4. After reboot

- Unlock your password manager / keyring
- Steam re-downloads games; Steam/Proton saves are not in the clone (use Steam Cloud if you rely on them)
- `ollama pull` for local models if you use them
- Re-enroll fingerprint if this machine has a reader
- Same YubiKey just works

## What restore will not do

It will not copy the old machine’s `fstab`, LUKS header, Limine `PARTUUID`, hostname, NetworkManager, systemd units under `/etc`, or GPU/CPU packages. Identity packages and FIDO2 bits can come back. Use `omaclone doctor` if a NAS mount or uid mapping looks wrong.
