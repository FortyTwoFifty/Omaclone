# Adding an omaclone backend

omaclone never hard-codes Proton Pass, NFS, or a vendor. It discovers executables:

```
<tool>/backends/<kind>/<id>          # shipped
~/.config/omaclone/backends/<kind>/<id>   # yours, wins on name clash
```

`kind` is `secrets`, `transport`, or `notify`. The file must be executable. First argument is the verb. stdout is data; stderr is messages; exit 0 is success. **Never print secrets to stderr, the journal, or argv.**

The setup wizard lists **all** shipped backends; unavailable ones are labeled `[not installed]`. When you pick one, the wizard installs its CLI (pacman for distro packages, curl installers for `op`/`pass-cli`) before continuing. Backends whose `available` exits 0 are always shown as available.

## Secrets

| Verb | Contract |
|---|---|
| `id` | Stable id (usually the filename) |
| `describe` | One line for `gum choose` |
| `available` | 0 if the CLI is installed |
| `setup` | Write non-secret keys into `$NAS_BACKUP_CONFIG` via `scripts/config.py`. Do not print the password. |
| `get` | Print **only** the restic password on stdout. The core redirects this onto a `600` tmpfs file and unlinks it after restic exits. |
| `put` | Optional. Read the password from stdin and store it. `prompt` must not implement this. |
| `unlock` | Optional. Interactive sign-in for the password manager. Not a secret. Attach stdio to /dev/tty. Exit 2 if unsupported. |
| `install` | Optional. Install missing CLI dependencies (e.g., pacman for libsecret, curl zip for `op`). Exit 0 if already available or no install needed. Called by the wizard before `setup`. |
| `update` | Optional. Install a newer version of the CLI tool when it reports an update is available. Attach stdio to /dev/tty. Exit 2 if unsupported. |

Environment provided by the loader: `NAS_BACKUP_ROOT`, `NAS_BACKUP_CONFIG`, `NAS_BACKUP_USER_CONFIG_DIR`.

Copy `backends/secrets/example` to `~/.config/omaclone/backends/secrets/bitwarden`, implement `available`/`get`, `chmod +x`. It will show up in `omaclone setup` with no core changes.

Password handling rules (enforced for shipped backends, required for drop-ins):

- Hidden input (`gum input --password`) if you must prompt
- Never `restic --password` / `-p`
- Never write the password to `$HISTFILE`, journald, or `config.toml`
- `get` stdout is a pipe, not a terminal

## Transport

Verbs: `id`, `describe`, `available`, `setup`, `mount`, `unmount`, `ready`, `bootstrap-install`, plus:

| Verb | Contract |
|---|---|
| `capabilities` | Space-separated flags. Unknown backends are treated as `mount`. Flags: `mount` (local filesystem), `remote` (restic URL, no mount), `removable` (cold disk; cron skips if missing), `discover` (can list restore locations). |
| `credential-keys` | Names of transport secrets (not the restic password), one per line, e.g. `s3-access-key`. Empty if none. |
| `discover` | Optional. One JSON object per line: `id`, `label`, `uri`, `hint`, optional `config` / `restore` paths. |
| `pre-restic` | Optional. Called after the tmpfs env file is created (`$NAS_BACKUP_ENVFILE`). S3 writes `AWS_*` there. Cold disks mount. |
| `post-restic` | Optional. Cold disks unmount. |

`bootstrap-install` must copy the tool tree plus `restore` and a **non-secret** `config.toml` onto the share so a blank Omarchy box can run `/mnt/omaclone/restore`. Use `scripts/bootstrap_copy.py`. S3 cannot ship a runnable launcher; print a note and exit 0.

Shipped transports: `nfs`, `cifs`, `sftp`, `disk`, `s3`, `local`.

## Notify

Verbs: `id`, `describe`, `available`, `send <title> <body> [urgency]`.
