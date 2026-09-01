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

Setup installs any missing **required** packages at start. Destination, password-manager, and notification CLIs are **optional** and only installed if you pick them — see [Dependencies](#dependencies).

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

Neither command deletes `~/.config/omaclone`, `~/.local/share/omaclone`, or clones stored on NAS, disk, or cloud. NFS systemd mount units created during setup stay until you disable them. Extra disks do not get systemd mount units unless you add them yourself.

---

## Dependencies

Omaclone is MIT-licensed ([LICENSE](LICENSE)). It needs a normal Omarchy box (bash, systemd, `python3`, `util-linux`). Everything else is listed below.

The wizard installs missing **required** packages with `sudo pacman -S --needed`. Optional backend CLIs are labeled `[not installed]` until you pick that destination or secrets source. Pacman packages are installed from the distro repos. 1Password (`op`) and Proton Pass (`pass-cli`) use their official installers; you confirm before any remote download.

### Required

| Package | Provides | Notes |
|---|---|---|
| `restic` | Encrypted snapshots | Core clone/restore engine |
| `jq` | JSON | Status, locations, bar pane |
| `gum` | TUI | Setup, restore, and confirmations. Ships with Omarchy |
| `rsync` | File copy | Staging dumps and bootstrap kit |
| `curl` | HTTP | Core setup; also used by the optional `op` / `pass-cli` installers |
| `python` | `python3` | `config.toml` and disk/bootstrap helpers. Already on Omarchy; not auto-installed |

`findmnt` and `lsblk` come from `util-linux` (base). `sudo` is used for pacman and, if you choose NFS or an extra disk, for systemd `.mount` / `.automount` units.

### Optional — destination

Installed only for the transport you pick.

| When | Package | Provides |
|---|---|---|
| NAS over NFS | `nfs-utils` | `mount.nfs` / `mount.nfs4` |
| NAS over SMB | `cifs-utils` | `mount.cifs`. Share password goes in Omaclone’s GNOME Keyring collection (`libsecret`) |
| NAS over SFTP | `openssh` | `ssh`, `scp` |
| Extra disk | — | Uses `lsblk` / `findmnt`. USB/hotplug defaults to `udisksctl` (mount while cloning). The system disk and EFI partitions are never offered. Clones live in `<mount>/omaclone/`. Formatting a blank disk needs `mkfs.ext4` (`e2fsprogs`) |
| S3-compatible cloud | — | Restic’s native S3 backend. Access keys go in Omaclone’s GNOME Keyring collection, never `config.toml`. Setup shows per-provider requirements first (AWS IAM policy, R2 token, Wasabi region URL, B2 S3 endpoint). AWS uses `s3.<region>.amazonaws.com` (restic docs); R2 uses `<accountid>.r2.cloudflarestorage.com` and region `auto`; Wasabi uses the region service URL; B2 uses the S3 endpoint on the bucket page; MinIO defaults to HTTP |
| Already-mounted path | — | No extra packages |

### Optional — restic password

Pick one in setup. Paste-each-time needs nothing extra and cannot run from the daily timer.

| Backend | Package / CLI | Install |
|---|---|---|
| GNOME Keyring | `libsecret` + `python-gobject` | pacman. Restic / S3 / SMB secrets go in a dedicated Omaclone collection, not the default desktop keyring |
| 1Password | `op` | Official zip from AgileBits into `~/.local/bin/op` (needs `unzip`) |
| Proton Pass | `pass-cli` | Official installer from proton.me, after confirmation |
| Prompt each time | — | No extra CLI |

### Optional — notifications

| Package | Provides | Notes |
|---|---|---|
| `libnotify` | `notify-send` | Desktop notices for clone success, skip, and failure. Clone still works without it |

### Optional — tests

`node` is only needed for `node ./tests/test-model.js`. The shell tests use the required tools above.

---

## First-time setup

`omaclone setup` is a gum TUI. It never writes the restic password to disk. Each screen is one question. A one-line hint appears only on the field it applies to (for example Mapall next to the NFS URI, IAM next to the AWS bucket). `omaclone location add` uses the same flow. Walkthroughs and copy-paste policy JSON are in [Destinations](#destinations) and [Security](#security) below. Omaclone does not create NAS shares, S3 buckets, or IAM users.

1. **Create a clone** or **restore from an existing one**.
2. **Where it lives**
   - NAS (TrueNAS, Synology, Unraid, …) via NFS, SMB, or SFTP
   - Extra disk (USB is cold / timer off; a 2nd NVMe can be hot / timer on)
   - S3-compatible cloud (Cloudflare R2, AWS, Wasabi, Backblaze B2 S3 API, MinIO)
   - A path that is already mounted
3. **How to get the restic password** — Proton Pass (`pass-cli`), 1Password (`op`), GNOME Keyring, or paste each time (nothing stored).
4. **How long to keep clones** — last 5, 7 days, 30 days, 3 months, 1 year, or the standard mix (7 daily / 4 weekly / 6 monthly / 2 yearly).
5. Optional: enable the daily timer, initialize the restic repo, run the first clone.

It writes a **recovery card** to `~/.local/share/omaclone/RECOVERY.md` (no passwords, no access keys): where the clone is and how to restore it on a new computer. Keep that card with the restic password.

### If you stop midway or a password manager fails

- Proton Pass (`pass-cli`) and 1Password (`op`) must be signed in. Setup offers Sign in, retry, change vault/item/field, paste this time, or continue later.
- Re-run `omaclone setup` to resume. A saved destination does not trap you in "already configured" until the restic repo is initialized **and** a location is registered. Missing CLIs for a saved backend are installed again on resume.
- `omaclone setup secrets` changes how omaclone gets the restic password without redoing the NAS/disk/cloud destination. The keyring offer resets so you can be asked again when switching away from keyring.
- Same retry UI is used later for clone/restore if the manager is locked. When a CLI prints an update notice, the failure menu offers "Install the available update" near Sign in; after a successful unlock/get on TTY it may also offer to store the password in the local keyring so the daily timer can run without 1Password or Proton Pass being signed in.
- Other cases you can continue later: restic init not done yet; S3/SMB keys missing (re-enter from setup); restore on a machine with no secrets backend chosen yet.

Prefer a dedicated NAS dataset or a disk you are willing to use only for clones. The wizard mounts or initializes storage you already have; it does not create NAS shares for you.

### NFS

Setup checks each NFS field (URI `host:/export`, local mountpoint, restic repo path) and **probes the export with a timed test mount before installing systemd `.mount` / `.automount` units**. A typo, a down NAS, or a path that is not exported fails in the wizard and does not leave orphan system services. If an automount is installed and still does not come up, the units are rolled back. The NFS URI prompt reminds you the export must be writable as this uid (TrueNAS **Mapall** / Synology squash).

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

That launcher lives next to the encrypted restic repo (`RESTORE.md` + `config.toml` + `SHA256SUMS` + `./restore`). It has **no passwords**. Prefer a plugin install from git; a kit copy that does not match `SHA256SUMS` asks you to type `UNTRUSTED`.

**Cloud, or you only have this plugin:**

```bash
omarchy plugin add https://github.com/FortyTwoFifty/Omaclone.git --enable
~/.config/omarchy/plugins/omaclone.plugin/scripts/omaclone restore
```

S3 has no `./restore` file. Re-enter access keys on the new machine; they are not on the recovery card.

The TUI asks for the restic password, lets you pick a snapshot (host + time), and **overlays** `$HOME`. Type `RESTORE` to continue. Extra files already on this home stay unless you pass `--delete` and type `REPLACE`. ssh, gpg, browsers, and desktop keyring files come back with home.

It will **not** copy `fstab`, LUKS headers, Limine `PARTUUID`, hostname, or GPU/CPU packages. `--same-machine` means you replaced the boot drive in this PC: it can offer hardware packages from the clone, and still refuses bootloader and LUKS files.

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
| Extra disk | `disk` | USB stick / enclosure (cold, `udisksctl` mount on clone) or 2nd NVMe (hot, optional fixed mountpoint) |
| Cloud | `s3` | R2, AWS, Wasabi, B2 S3 API, MinIO |
| Already mounted | `local` | Pre-mounted path |

Vendor names are wizard hints, not separate backends. Synology does not need a DSM API: SMB or SFTP is enough.

**SMB:** UNC `//server/share`. The share password goes in the Omaclone keyring, never `config.toml` or `mount.cifs` argv. Omaclone does **not** install a CIFS automount — daily clones run only while the share is mounted. Use NFS if you want an always-on NAS.

**SFTP:** restic uses SSH with `BatchMode=yes` (keys only). Run `ssh-copy-id user@host` before setup; the daily timer cannot type a password.

**Cold USB:** plug it in. Setup mounts it with `udisksctl` (no sudo, no fixed path) and puts the restic repo in `omaclone/` on that volume — existing files stay. A preferred path (for example `/mnt/external-NVMe`) is attempted with sudo; if that fails, the desktop mount is used and setup still finishes. If it is unplugged when the daily timer fires, the clone is skipped and you get a notification — not a hard failure. Always-plugged extra disks can install a systemd mount and the daily timer. USB stays cold unless you opt in. ext4/btrfs/xfs are first-class; FAT/exFAT/NTFS work but are a poor choice for large clones. Omaclone does not encrypt the disk (LUKS is yours). Format is optional and destructive (`DESTROY`).

**Already mounted:** the path must already be mounted and writable. `/mnt`, `/media`, and `/run/media` are refused if not mounted. Do not put the repo under `$HOME`.

**S3** cannot ship a runnable `./restore` file — there is **no `./restore` file** in the bucket. Recovery is `omarchy plugin add` then the plugin-tree `omaclone restore`. Access keys live in the keyring, never in `config.toml`. Restic wants an **access key id** (`AKIA…` / `ASIA…`) and secret, not an IAM role ARN. Temporary `ASIA…` keys also need a session token.

Create the AWS bucket in the console first. Attach this policy to a **dedicated IAM user** (not the root account). `ListBucket` and `GetBucketLocation` are on the **bucket ARN** (no `/*`); object actions are on `bucket/*`. You do not paste those ARNs into the wizard — setup points here when you pick AWS.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ResticBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::BUCKET"
    },
    {
      "Sid": "ResticObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET/*"
    }
  ]
}
```

Other providers: R2 uses an Object Read & Write token and region `auto`; Wasabi needs the region service URL (`s3.wasabisys.com` is US East 1 only); B2 uses the S3 endpoint on the bucket page, not native `b2:`; MinIO may use HTTP.

You can register **more than one location** and switch the active one:

```bash
omaclone location              # list (NAS, USB, discovered sticks, …)
omaclone location add          # wizard for another NAS / disk / cloud
omaclone location switch nas   # make NAS active (enables the daily timer)
omaclone location switch usb   # make the USB active (timer off — it is detached)
omaclone location remove usb   # forget a saved location (does not erase the drive)
```

The daily timer follows **only the active location**. A USB that is unplugged is hidden from the pane and has no clone count. Plug it in and the count is read from the restic repo on the drive — nothing is stored on the machine. An empty disk (kit deleted) is dropped when that disk is mounted. Cloud locations keep the last clone count on this machine after a successful clone; they are not re-listed from S3 on every pane open.

Discovered volumes (USB or NAS mounts with an `omaclone/` kit — `restore` + `config.toml`, a bootstrap marker, or a restic `repo/config`) show up in `omaclone location` and in the bar Location radios. Switching one imports it. Empty drives stay hidden. The pane does not scan the LAN or mount unknown disks.

---

## Bar widget

Plugin id `omaclone.plugin`. Left-click the copied Omarchy mark on the bar.

- **Upper right of the pane:** copied Omarchy mark (the bar logo, stacked like a copy icon)
- **Locations:** radios for connected clone targets (USB only while plugged in) plus any mounted volume that looks like an Omaclone kit
- **Tiles:** clone count (dash when nothing is connected, or for S3 until a clone has run on this machine), storage (label + size), keep plan. USB/NAS count files on the volume. S3 uses the count saved after clone/prune — the bar does not list the bucket on refresh (no extra LIST/GET charges).
- **Keep:** click to change retention; a **tighter** plan prunes clones that fall outside it. Widening does not prune.
- **Storage:** the tile shows the active clone location; click it (or press `l`) to switch. Extra disks are not always labeled USB.
- **Actions:** setup (until configured), clone now, keep, clones, add location, restore

Right-click the chip (or press `r` in the pane) to refresh. Opening the pane also refreshes and searches mounted USB/NAS volumes for an Omaclone backup. Status is live health: whether each clone location is connected (disk plugged in, NAS mounted), not a stale last-result. Plug the drive back in and the not-connected / skipped-disk banner clears on the next refresh. While a disk or share is offline the chip polls every 10s and watches every installed UUID plus `last-result.json`. The chip uses the urgent color on error, a dimmer tone on warning, otherwise the bar foreground.

Daily clone is `omaclone.timer` (02:00, with jitter). Weekly prune is `omaclone-prune.timer`. The timer clones `$HOME` without a password prompt; `/etc` and package lists are included only when `sudo` can run non-interactively (Omarchy’s optional passwordless sudo).

Unattended clone needs a restic password with no terminal. **GNOME Keyring** can do that once Omaclone’s collection is unlocked: if the 02:00 timer fires while it is still locked, the chip turns the warning color and Omaclone waits, then clones automatically on the next unlock. **1Password** (`op`) and **Proton Pass** (`pass-cli`) must already be signed in; they cannot unlock themselves from a timer. If you keep using those instead of storing the restic password in the keyring, a locked or signed-out manager skips the automatic clone, the chip turns the warning color, and the pane says the last clone did not run. Clone from the pane after signing in, or accept the keyring offer so the timer can run on its own. The prompt-each-time backend never runs from the timer.

---

## Commands

```
omaclone setup [secrets|continue]       First-run or resume wizard; secrets reconfigures the password source
omaclone clone [--cron]                 Save an identity clone (alias: backup)
omaclone restore [--same-machine] [--snapshot ID] [--blank-omarchy] [--delete]
omaclone snapshots                      List restic snapshots
omaclone forget [ID...] [--all] [--yes] Remove clones from this location (alias: remove)
omaclone status [--json|--ack]          Last clone, size, keep plan, location connected
omaclone install                        PATH, timers, bar plugin
omaclone uninstall                      Remove PATH command, timers, plugin symlink, and our menu keys
omaclone check                          restic check
omaclone init                           restic init on the configured repo
omaclone prune                          Apply the keep plan and delete the rest
omaclone retention                      Show keep plan
omaclone retention set PRESET [--yes]   Change keep plan (prunes only if tighter)
omaclone location                       List clone locations (alias: locations)
omaclone location add                   Register another NAS / disk / cloud
omaclone location switch [ID]           Make a location active (timers follow it)
omaclone location remove [ID] [--yes]   Forget a location (does not erase the drive)
omaclone location schedule [ID] [on|off]
omaclone doctor                         Mount, uid mapping, repo path
omaclone estimate                       Size of $HOME after excludes
omaclone verify [--all]                 restic check of a data subset (or all packs)
omaclone copy [ID]                      Copy clones to another mounted location
omaclone --version                      Plugin version
```

Skip from the daily timer is exit 0 with a last-result; a real failure is exit 1.

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

- `$HOME` (configs, dotfiles, **ssh/gpg/browser profiles**, desktop keyring files, identity state, and game saves that live outside Steam)
- Allowlisted `/etc` paths only (currently FIDO2). Not `fstab`, `crypttab`, hostname, mkinitcpio, Limine, LUKS, shadow, NetworkManager, systemd, pam, polkit, or ssh — those are refused even if the allowlist file is edited
- Pacman identity packages (not GPU/firmware)
- Enabled user units, minus machine-local mounts (see `config/user-units.deny`)

**Not cloned**

- Steam libraries and Proton prefixes (`~/.local/share/Steam`, `~/.steam`, Flatpak `~/.var/app/com.valvesoftware.Steam`), including Steam/Proton saves
- Ollama models (`~/.ollama`)
- Package caches, `node_modules`, `.git/objects`
- Snapper snapshots, swap
- Other filesystems mounted under `$HOME` (`restic --one-file-system`)

Re-download games and `ollama pull` after restore.

Edit `config/excludes.txt` (gitignore-style, relative to `$HOME`) and `config/hardware-packages.txt` if you need to.

---

## Security

- Restic password is **never** in `config.toml`, shell history, journald, or `ps`. After it is read, the named tmpfs file is unlinked and restic is given `/dev/fd/N` only.
- Paste-once uses `gum input --password`. A generated password is printed to the tty by the shell, not passed to `gum` as an argument.
- Clone failures store a short mapped message (`password was rejected`, I/O, permission, no space). Restic stderr is not copied into `last-result.json`, desktop notifications, or the bar.
- Three different secrets: the **restic password** (encrypts the clone; lose it and snapshots are gone), the **Omaclone keyring password** (unwraps `omaclone.keyring`; not FIDO; asked in the terminal), and **transport secrets** (S3 keys, SMB password) in that same collection. Do not mix them up.
- SMB passwords and S3 keys use Omaclone’s own GNOME Keyring collection (or a prompt). Never the default desktop keyring, never `mount.cifs` argv. Writing to an unencrypted default keyring can make gnome-keyring refuse to load it after a secret with a newline is stored (Proton VPN and similar), which drops every other app’s saved passwords.
- Do not reuse login, LUKS, or password-manager master passwords for the restic repo.
- Bootstrap files next to the repo (`restore`, `config.toml`, `RESTORE.md`, `SHA256SUMS`) contain **no secrets**. `SHA256SUMS` covers the scripts and backends the kit will execute; it is not a signature. Prefer `omarchy plugin add` from git. The recovery card includes a kit tree digest you can compare.
- Prep never runs `sudo` on a script in the plugin tree. `/etc` collection is `sudo tar` with a fixed argv, written into a fresh staging directory as the user.
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
├── briefs/                # one-line field hints (full detail is in this README)
├── config/                # excludes, hardware skip list, /etc allowlist
├── scripts/omaclone       # CLI
├── systemd/               # user clone + prune timers
└── tests/                 # backend contract, migration, retention
```

Drop-in backends: `~/.config/omaclone/backends/<secrets|transport|notify>/<id>`. See [BACKENDS.md](BACKENDS.md).

---

## Development

```bash
make test          # or: ./tests/run.sh
```

That runs the contract tests, a hermetic restic round-trip (`init` → `clone --cron` → `restore --snapshot` → `forget`), the `--cron` skip matrix, systemd unit checks, `node ./tests/test-model.js`, and `omarchy plugin validate .` when `omarchy` is on PATH.

Individual files still work:

```bash
./tests/test-backend-contract.sh
./tests/test-transport-contract.sh
./tests/test-briefs.sh
./tests/test-migration.sh
./tests/test-retention.sh
./tests/test-locations.sh
./tests/test-nfs.sh
./tests/test-disk.sh
./tests/test-disk-candidates.sh
OMACLONE_DISK_LIVE=1 ./tests/test-disk-live.sh   # opt-in; needs a plugged extra disk
./tests/test-deps.sh
./tests/test-discover.sh
./tests/test-forget.sh
./tests/test-secrets-retry.sh
./tests/test-keyring-store.sh
./tests/test-install.sh
./tests/test-units.sh
./tests/test-cron-skip.sh
./tests/test-restic-roundtrip.sh
node ./tests/test-model.js
omarchy plugin validate .
```

Do not run a live `omaclone restore` against a lived-in home unless you mean it. The round-trip test uses an isolated temp `$HOME`.

---

## License

MIT. See [LICENSE](LICENSE).
