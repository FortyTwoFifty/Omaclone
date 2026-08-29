# Omaclone

**Identity clone for [Omarchy](https://omarchy.org/).** Encrypted [restic](https://restic.net/) snapshots of *you* — home, configs, identity packages, game saves — stored on a NAS, extra disk, USB stick, or S3-compatible cloud. After a stock Omarchy install on a new disk or a new PC, restore the clone and keep going.

Omarchy’s built-in **Snapper snapshots** undo a breaking change on the *same* machine. They live on that disk and do not include `@home`. Omaclone is the other half: it survives a wiped drive, a full reinstall, and a hardware swap. It does **not** clone the OS, LUKS, Btrfs layout, Limine, or GPU stack. Those come from the installer.

Plugin id: `omaclone.plugin`. CLI: `omaclone`.

---

## Install

On an Omarchy machine:

```bash
omarchy plugin add https://github.com/FortyTwoFifty/Omaclone.git --enable
~/.config/omarchy/plugins/omaclone.plugin/scripts/omaclone setup
```

`plugin add` only clones the bar widget — `omaclone` is not on PATH until setup (or click the chip → Set up Omaclone). Setup installs the PATH command, daily timer, prune timer, and Super+Space menu entries.

Or clone the tree and run the wizard from there:

```bash
git clone https://github.com/FortyTwoFifty/Omaclone.git
cd Omaclone
./scripts/omaclone setup
```

After setup, `omaclone` lands on PATH; `omarchy-backup` and `nas-backup` remain aliases.

Requires a normal Omarchy box: `restic`, `jq`, `gum`, `rsync` (installed if missing). NFS/SMB/SFTP/disk tools are pulled in only for the destination you pick.

The wizard installs any missing core dependencies at start. If you select a backend whose CLI is absent, it lists `[not installed]` and offers to install it before continuing — pacman for distro packages, official curl installers for 1Password (`op`) and Proton Pass (`pass-cli`). You confirm before any remote download.

### Configure

```bash
omarchy bar move omaclone.plugin --section right
```

`omaclone setup` writes `~/.config/omaclone/config.toml` only after you confirm each step. It does not overwrite an existing restic repository.

### Remove

```bash
omaclone uninstall
omarchy plugin remove omaclone.plugin
```

Run `uninstall` first while the plugin tree is still present. It removes the PATH command and daily/prune timers. `omarchy plugin remove omaclone.plugin` unloads the bar widget. If you never ran setup, only the second command is needed.

Neither command deletes `~/.config/omaclone`, `~/.local/share/omaclone`, or clones stored on NAS, disk, or cloud. NFS or extra-disk systemd mount units created during setup stay until you disable them.

---

## First-time setup

`omaclone setup` is a gum TUI. It never writes the restic password to disk.

1. **Create a clone** or **restore from an existing one**.
2. **Where it lives**
   - NAS (TrueNAS, Synology, Unraid, …) via NFS, SMB, or SFTP
   - Extra disk (2nd NVMe, USB, cold/off-site drive)
   - S3-compatible cloud (Cloudflare R2, AWS, Wasabi, Backblaze B2 S3 API, MinIO)
   - A path that is already mounted
3. **How to get the restic password** — Proton Pass (`pass-cli`), 1Password (`op`), GNOME Keyring, or paste each time (nothing stored).
4. **How long to keep clones** — last 5, 7 days, 30 days, 3 months, 1 year, or the standard mix (7 daily / 4 weekly / 6 monthly / 2 yearly).
5. Optional: enable the daily timer and bar widget, initialize the restic repo, run the first clone.

It writes a **recovery card** to `~/.local/share/omaclone/RECOVERY.md` (no passwords, no access keys): where the clone is and how to restore it on a new computer. Keep that card with the restic password.

### If you stop midway or a password manager fails

- Proton Pass (`pass-cli`) and 1Password (`op`) must be signed in. Setup offers Sign in, retry, change vault/item/field, paste this time, or continue later.
- Re-run `omaclone setup` to resume. A saved destination does not trap you in "already configured" until the restic repo is initialized **and** a location is registered. Missing CLIs for a saved backend are installed again on resume.
- `omaclone setup secrets` changes how omaclone gets the restic password without redoing the NAS/disk/cloud destination. The keyring offer resets so you can be asked again when switching away from keyring.
- Same retry UI is used later for clone/restore if the manager is locked. When a CLI prints an update notice, the failure menu offers "Install the available update" near Sign in; after a successful unlock/get on TTY it may also offer to store the password in the local keyring so the backend tool isn't needed every run.
- Other cases you can continue later: restic init not done yet; S3/SMB keys missing (re-enter from setup); restore on a machine with no secrets backend chosen yet.

Prefer a dedicated NAS dataset or a disk you are willing to use only for clones. The wizard mounts or initializes storage you already have; it does not create NAS shares for you.

### NFS

Setup checks each NFS field (URI `host:/export`, local mountpoint, restic repo path) and **probes the export with a timed test mount before installing systemd `.mount` / `.automount` units**. A typo, a down NAS, or a path that is not exported fails in the wizard and does not leave orphan system services. If an automount is installed and still does not come up, the units are rolled back.

NFS uses numeric UIDs. If `ls` on the export shows an owner other than your Linux uid (usually 1000), writes fail.

- TrueNAS: Shares → Unix Shares (NFS) → Advanced Options → Mapall User/Group = the NAS account that owns the dataset.
- Synology: NFS squash / “map all users” to the folder owner.

Do not convert a browse-only SMB mount to NFS just to fix this. Use a dedicated backup export.

---

## Disaster restore (new disk or new PC)

1. Install stock Omarchy. Use the **same username** if you can.
2. Reach the clone, then restore.

**USB / extra disk / NAS share** — plug in or mount it (locator is on the recovery card):

```bash
/path/to/clone/restore
```

That launcher lives next to the encrypted restic repo (`RESTORE.md` + `config.toml` + `./restore`). It has **no passwords**.

**Cloud, or you only have this plugin:**

```bash
omarchy plugin add https://github.com/FortyTwoFifty/Omaclone.git --enable
~/.config/omarchy/plugins/omaclone.plugin/scripts/omaclone restore
```

The TUI installs dependencies if needed, asks for the restic password (password manager, keyring, or a one-time paste), lets you pick a snapshot, and overlays `$HOME`. Type `RESTORE` if home is not empty.

It will **not** copy `fstab`, LUKS headers, Limine `PARTUUID`, hostname, or GPU/CPU packages. That is what makes restore work on different hardware.

`--same-machine` means “I replaced the boot drive in this PC.” It still refuses bootloader and LUKS files.

### After reboot

- Unlock your password manager / keyring
- Steam re-downloads games; Steam/Proton saves are **not** in the clone (use Steam Cloud if you rely on them)
- `ollama pull` for local models if you use them
- Re-enroll fingerprint if this machine has a reader
- The same YubiKey just works (FIDO2 bits under `/etc` are allowlisted)

A longer walkthrough is in [RESTORE.md](RESTORE.md).

---

## Destinations

| Profile | Transports | Typical use |
|---|---|---|
| NAS | `nfs`, `cifs`, `sftp` | TrueNAS, Synology, Unraid, generic Unix/SMB |
| Extra disk | `disk` | 2nd NVMe (hot, always mounted) or USB (cold, mount on clone) |
| Cloud | `s3` | R2, AWS, Wasabi, B2 S3 API, MinIO |
| Already mounted | `local` | Pre-mounted path |

Vendor names are wizard hints, not separate backends. Synology does not need a DSM API: SMB or SFTP is enough.

**Cold USB:** if the disk is unplugged when the daily timer fires, the clone is skipped and you get a notification — not a hard failure.

**S3** cannot ship a runnable `./restore` file. Recovery is `omarchy plugin add` then the plugin-tree `omaclone restore`. Access keys live in the keyring, never in `config.toml`.

You can register **more than one location** and switch the active one:

```bash
omaclone location              # list (NAS, USB, discovered sticks, …)
omaclone location add          # wizard for another NAS / disk / cloud
omaclone location switch nas   # make NAS active (enables the daily timer)
omaclone location switch usb   # make the USB active (timer off — it is detached)
omaclone location remove usb   # forget a saved location (does not erase the drive)
```

The daily timer follows **only the active location**. A USB that is unplugged is hidden from the pane and has no clone count. Plug it in and the count is read from the restic repo on the drive — nothing is stored on the machine. An empty disk (kit deleted) is dropped when that disk is mounted.

Discovered volumes (USB or NAS mounts with an `omaclone/` kit — `restore` + `config.toml`, a bootstrap marker, or a restic `repo/config`) show up in `omaclone location` and in the bar Location radios. Switching one imports it. Empty drives stay hidden. The pane does not scan the LAN or mount unknown disks.

---

## Bar widget

Plugin id `omaclone.plugin`. Left-click the copied Omarchy mark on the bar.

- **Upper right of the pane:** copied Omarchy mark (the bar logo, stacked like a copy icon)
- **Locations:** radios for connected clone targets (USB only while plugged in) plus any mounted volume that looks like an Omaclone kit
- **Tiles:** live clone count from the connected drive (hidden when nothing is plugged in), connected storage, keep plan
- **Keep:** click to change retention; confirming a tighter plan prunes clones that fall outside it
- **Storage:** the tile shows the active clone location; click it (or press `l`) to switch
- **Actions:** setup, clone now, list snapshots, restore

Right-click the chip (or press `r` in the pane) to refresh. Opening the pane also refreshes and searches mounted USB/NAS volumes for an Omaclone backup. Status is live health: whether each clone location is connected (disk plugged in, NAS mounted), not a stale last-result. Plug the drive back in and the not-connected / skipped-disk banner clears on the next refresh. While a disk or share is offline the chip polls every 10s and watches every installed UUID plus `last-result.json`. The chip uses the urgent color on error, a dimmer tone on warning, otherwise the bar foreground.

Daily clone is `omaclone.timer` (02:00, with jitter). Weekly prune is `omaclone-prune.timer`. The timer clones `$HOME` without a password prompt; `/etc` and package lists are included only when `sudo` can run non-interactively (Omarchy’s optional passwordless sudo).

---

## Commands

```
omaclone setup [secrets|continue]       First-run or resume wizard; secrets reconfigures the password source
omaclone clone [--cron]                 Save an identity clone (alias: backup)
omaclone restore [--same-machine] [--snapshot ID]
omaclone snapshots                      List restic snapshots
omaclone forget [ID...] [--all] [--yes] Remove clones from this location
omaclone status [--json|--ack]          Last clone, size, keep plan, location connected
omaclone install                        PATH, timers, bar plugin
omaclone uninstall                      Remove PATH command, timers, and plugin symlink
omaclone check                          restic check
omaclone init                           restic init on the configured repo
omaclone prune                          Apply the keep plan and delete the rest
omaclone retention                      Show keep plan
omaclone retention set PRESET [--yes]   Change keep plan (confirms, then prunes)
omaclone location                       List clone locations
omaclone location add                   Register another NAS / disk / cloud
omaclone location switch [ID]           Make a location active (timers follow it)
omaclone location remove [ID] [--yes]   Forget a location (does not erase the drive)
omaclone doctor                         Mount, uid mapping, repo path
```

### Retention presets

| Preset | Keep |
|---|---|
| `last-5` | Last 5 clones |
| `week` | Last 7 days |
| `month` | Last 30 days |
| `quarter` | 7 daily / 4 weekly / 3 monthly |
| `year` | 7 daily / 4 weekly / 12 monthly / 1 yearly |
| `standard` | 7 daily / 4 weekly / 6 monthly / 2 yearly (default) |

Change this in setup, the bar pane, the Omarchy menu (**Omaclone → Keep plan…**), or `omaclone retention set`. Shortening the plan asks for confirmation, then prunes.

---

## What is cloned / what is not

**Cloned**

- `$HOME` (configs, dotfiles, identity state, and game saves that live outside Steam)
- Allowlisted `/etc` paths only (currently FIDO2). Not `fstab`, `crypttab`, hostname, mkinitcpio, Limine, LUKS, shadow, or NetworkManager — those are refused even if the allowlist file is edited
- Pacman identity packages (not GPU/firmware)
- Enabled user units, minus machine-local mounts (see `config/user-units.deny`)

**Not cloned**

- Steam libraries and Proton prefixes (`~/.local/share/Steam`, `~/.steam`), including Steam/Proton saves
- Ollama models (`~/.ollama`)
- Package caches, `node_modules`, `.git/objects`
- Snapper snapshots, swap
- Other filesystems mounted under `$HOME` (`restic --one-file-system`)

Re-download games and `ollama pull` after restore.

Edit `config/excludes.txt` (gitignore-style, relative to `$HOME`) and `config/hardware-packages.txt` if you need to.

---

## Security

- Restic password is **never** in `config.toml`, shell history, journald, or `ps`.
- Paste-once uses `gum input --password` and a mode `600` tmpfs file, shredded when restic exits.
- SMB passwords and S3 keys use the keyring (or a prompt). Never on `mount.cifs` argv.
- Do not reuse login, LUKS, or password-manager master passwords for the restic repo.
- Bootstrap files next to the repo (`restore`, `config.toml`, `RESTORE.md`) contain **no secrets**.
- LUKS headers are not collected.

Config: `~/.config/omaclone/config.toml` (mode `600`).  
State: `~/.local/share/omaclone/` (last result, repo stats, recovery card, staging dumps).

---

## Layout

```
Omaclone/
├── manifest.json          # Omarchy plugin (omaclone.plugin)
├── Panel.qml              # Bar chip + popup
├── backends/              # secrets / transport / notify
├── config/                # excludes, hardware skip list, /etc allowlist
├── scripts/omaclone       # CLI
├── systemd/               # user clone + prune timers
└── tests/                 # backend contract, migration, retention
```

Drop-in backends: `~/.config/omaclone/backends/<secrets|transport|notify>/<id>`. See [BACKENDS.md](BACKENDS.md).

---

## Development

```bash
./tests/test-backend-contract.sh
./tests/test-transport-contract.sh
./tests/test-migration.sh
./tests/test-retention.sh
./tests/test-locations.sh
./tests/test-nfs.sh
./tests/test-disk.sh
./tests/test-deps.sh
./tests/test-discover.sh
./tests/test-forget.sh
./tests/test-secrets-retry.sh
./tests/test-install.sh
node ./tests/test-model.js
omarchy plugin validate .
```

Do not run a live `omaclone restore` against a lived-in home unless you mean it.

---

## License

MIT. See [LICENSE](LICENSE).
