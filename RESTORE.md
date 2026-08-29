# Restore this Omarchy identity with Omaclone

You are on a **new** disk or computer. Omarchy is already installed. This file lives next to the encrypted restic repo (or with the plugin) and has **no passwords**.

## 1. Network (skip for a local disk)

Plug in Ethernet (or join Wi-Fi) if the clone is on a NAS or in the cloud.

## 2. Reach the clone

**USB / extra disk** — plug it in. If it does not automount:

```bash
lsblk
sudo mkdir -p /mnt/omaclone
sudo mount /dev/disk/by-uuid/UUID /mnt/omaclone
```

The clone lives in an `omaclone/` folder on the disk (restic `repo/`, `restore`, `config.toml`).

**NFS:**

```bash
sudo pacman -S --needed nfs-utils
sudo mkdir -p /mnt/omaclone
sudo mount -t nfs4 HOST:/EXPORT /mnt/omaclone
ls /mnt/omaclone/omaclone
```

**SMB:**

```bash
sudo pacman -S --needed cifs-utils
sudo mkdir -p /mnt/omaclone
sudo mount -t cifs //HOST/SHARE /mnt/omaclone -o uid=$(id -u),gid=$(id -g)
```

Replace `HOST:/EXPORT`, `//HOST/SHARE`, or `UUID` with the locator from your recovery card (also in `config.toml` on a share).

## 3. Run the TUI

From a share or disk that has the bootstrap copy:

```bash
/mnt/omaclone/omaclone/restore
```

From the plugin on a blank Omarchy box (cloud, or you installed the plugin):

```bash
omarchy plugin add https://github.com/FortyTwoFifty/Omaclone.git --enable
~/.config/omarchy/plugins/omaclone.plugin/scripts/omaclone restore
```

It installs `restic`, `jq`, `gum`, and `rsync` if needed, then asks for the restic password:

- Proton Pass / 1Password / keyring if that is how this repo was created
- Or paste the password once (it is not saved, not logged)

Pick a snapshot. Type `RESTORE` if home is not empty. Reboot when it finishes.

## 4. After reboot

- Unlock your password manager
- Steam re-downloads games; Steam/Proton saves are not in the clone (use Steam Cloud if you rely on them)
- `ollama pull` for local models if you use them
- Re-enroll fingerprint if this machine has a reader
- Same YubiKey just works

## What restore will not do

It will not copy the old machine’s `fstab`, LUKS header, Limine `PARTUUID`, hostname, or GPU/CPU packages. That is what makes this work on different hardware.

`--same-machine` only means “I replaced the boot drive in this PC.” It still refuses bootloader and LUKS files.
