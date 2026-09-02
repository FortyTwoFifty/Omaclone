# Restore this Omarchy identity with Omaclone

You are on a **new** disk or computer. Omarchy is already installed. This file lives next to the encrypted restic repo (or with the plugin) and has **no passwords**.

The clone is an **overlay** of `$HOME`, not a wipe. ssh, gpg, browsers, desktop keyring files, and other Omarchy plugins come back. The Omaclone plugin tree itself is left alone. Extra files already on this home stay unless you pass `--delete` and type `REPLACE`.

Install Omarchy with the **same username** if you can. Restore can remap a single home from the snapshot onto `$HOME`; several homes in one snapshot cannot be guessed.

## 1. Network (skip for a local disk)

Plug in Ethernet (or join Wi-Fi) if the clone is on a NAS or in the cloud.

## 2. Reach the clone

The kit is `$mount/omaclone/` (`restore`, `config.toml`, `RESTORE.md`, `SHA256SUMS`, `config/omaclone-kit.sig`, restic `repo/`). If the volume is mounted at `/mnt/omaclone`, the launcher is `/mnt/omaclone/omaclone/restore`.

On a blank PC, `~/.local/share/omaclone/RECOVERY.md` is not there yet. Use the locator from the printed/saved recovery card, or from `config.toml` on the share/disk once it is mounted (`transport.uri`, `transport.mountpoint`, `transport.uuid`, or the S3 endpoint/bucket).

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

**SFTP:** key-only. First connection needs `known_hosts` (`ssh user@host` once). There is no local `./restore` until you copy the kit. Prefer the plugin path in step 3, then `omaclone restore` and pick SFTP (host, user, remote directory next to `repo/`, default `omaclone/`). `ssh-copy-id` must already have been done from this machine, or copy the kit with `scp -r user@host:omaclone /mnt/omaclone` and run `/mnt/omaclone/omaclone/restore`.

**S3:** no `./restore` on the bucket. Install the plugin (step 3) and re-enter access keys. They are not on the recovery card.

Replace `HOST:/EXPORT`, `//HOST/SHARE`, or `UUID` with the locator from the recovery card or kit `config.toml`.

## 3. Run the TUI

From a share or disk that has the bootstrap copy:

```bash
/mnt/omaclone/omaclone/restore
```

Prefer a plugin install from git. The kit verifies an Ed25519 signature of the tool tree with the public key embedded in `./restore`. A missing or unknown signature stops; it does not offer `UNTRUSTED`. An interactive kit restore then asks you to type **`TRUST`** before using that copy’s host or bucket in `config.toml`.

From the plugin on a blank Omarchy box (cloud, SFTP, or you installed the plugin):

```bash
omarchy plugin add https://github.com/FortyTwoFifty/Omaclone.git --enable
~/.config/omarchy/plugins/omaclone.plugin/scripts/omaclone restore
```

It installs `restic`, `jq`, `gum`, and `rsync` if needed, then asks for the restic password:

- Proton Pass / 1Password / keyring if that is how this repo was created
- Or paste the password once (it is not written to `config.toml` or shell history; after a successful get the TUI may offer to store it in the local keyring)

On a new PC the local keyring is empty — paste or sign in to the password manager.

The TUI asks whether this is the same PC (you replaced the boot drive) even if you did not pass `--same-machine`. Pick a snapshot (hostname + time). Type `RESTORE` to overlay `$HOME`. `--same-machine` can install hardware packages and still refuses LUKS/bootloader files.

Enabling cloned user systemd units, and lingering login for timers, are separate confirmations (default off).

If the username on this box is different, restore remaps a single home from the snapshot onto `$HOME`. Several homes in one snapshot cannot be guessed.

## 4. After reboot

- Unlock your password manager / keyring
- Steam re-downloads games; Steam/Proton saves are not in the clone (use Steam Cloud if you rely on them)
- `ollama pull` for local models if you use them
- Re-enroll fingerprint if this machine has a reader
- Same YubiKey just works — FIDO2 bits under `/etc` are allowlisted

## What restore will not do

It will not copy the old machine’s `fstab`, LUKS header, Limine `PARTUUID`, hostname, NetworkManager, systemd units under `/etc`, or GPU/CPU packages. Identity packages and FIDO2 bits can come back. User units under `~/.config/systemd/user` are only re-enabled if you confirm. Use `omaclone doctor` if a NAS mount or uid mapping looks wrong.
