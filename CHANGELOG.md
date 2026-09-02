# Changelog

## 1.6.1

- Privileged helper is installed to root-owned `/usr/lib/omaclone/privileged.py` (owner/mode/digest checked). Inherited `_OMACLONE_PRIVILEGED_B64` is ignored; sudo no longer interpolates payload into `python3 -c`.
- Disk format requires `/dev/disk/by-id`, derives the sysfs ancestor/descendant/holder/slave graph itself, and refuses system/swap/mounted relations. `mkfs.ext4` inherits the held device fd via `pass_fds`.
- Systemd unit publish refuses to replace a foreign unit. Rollback undoes only this transaction (unlink created files; restore replaced Omaclone artifacts).
- Status/discovery helper streams and caps stdout/stderr incrementally and forwards termination to the whole process group.
- `/etc` tar restore iterates members and rejects the archive when member, directory, or uncompressed-byte limits are exceeded.

## 1.6.0

- Privileged NFS/disk unit install no longer `sudo cp`s files from a user temp dir. A slurped root helper generates units from validated URI/UUID/mountpoint data, publishes them with exclusive no-follow opens, checks ownership/mode, enables, and rolls back on failure.
- Extra-disk format binds major:minor, size, by-id, serial, and system-disk ancestry at pick time and revalidates on the privileged side immediately before `mkfs.ext4 -F`.
- `/etc` restore extracts with a link/device-rejecting implementation on every Python, then a privileged restorer publishes only the closed `fido2` allowlist via held directory fds as root-owned `0644` files (no `cp -a` of user staging).
- Recovery kit authentication is a project Ed25519 signature of the canonical tree digest (`config/omaclone-kit.sig`), verified with a public key embedded in `./restore` before any other kit code or package install. Missing/unknown signatures fail closed. `SHA256SUMS` is a human checksum list only.
- `omaclone uninstall` records installed artifacts and removes matching NFS/disk system units (content-hash checked), user units, PATH links, menu keys, and linger.
- Bar status/discovery helpers cap stdout, schema, locations, and watch paths. Every process tree has a deadline with TERM then KILL.
- CI declares `permissions: contents: read`, pins `actions/checkout` and the MinIO image to digests, and installs gum from a checksummed GitHub release.

## 1.5.1

- User timer units use `ProtectSystem=true` instead of `strict`. `strict` remounts `/mnt` and `/run/media` read-only, so daily NAS and USB clones failed. Re-run `omaclone install` to copy the new units.
- Connecting to a cloud location (setup of an existing repo, location switch, or the bar when the count is still unknown) queries how many clones are there and caches the result. Same for NAS/disk/USB that already have clones. Status polls still do not list the bucket on every refresh.
- README and kit `RESTORE.md` match 1.5.1: `TRUST` before kit `config.toml`, locators from the recovery card or kit config (not `~/.local/share` on a blank PC), saved locations are never auto-dropped, and timer `/etc` vs package-list sudo is accurate.
- `config.py` no longer `chmod 700`s `/tmp` (or other system dirs) when the config file lives there.
- Restore `--delete` uses `--delete-after` and excludes live `restore-staging`. `/etc` extras, pkglists, and user units are read from the restic extract, not leftover local staging. Other Omarchy plugins restore; only `omaclone.plugin` is excluded. User units and linger ask before enabling. `etc.tar` uses tarfile `filter="data"`.
- `omaclone copy` remaps the dest onto the live mount, refuses to init a repo on `/`, and runs through the same AWS-env helper as clone. SFTP kit copy passes `scp -r --`.
- Local/NFS/CIFS `ready` uses exact `findmnt -M`. Disk setup validates mountpoints before sudo. System-disk sibling partitions are not offered for format. NFS probe mounts are `nosuid,nodev,noexec`. Saved locations are never auto-dropped from status.
- Setup “continue later” on restic init does not register the location or install timers. Interactive CIFS/NFS/disk/keyring sudo uses `/dev/tty`. Keyring-retry timeout is 21h. Uninstall stops oneshot services and clears linger when Omaclone enabled it.
- Bar: `watchPaths` no longer rebuilds FileViews every poll; empty helper stdout backs off; a failed location switch reverts the radio; KEEP is disabled until setup is complete.

## 1.5.0

- Kit `SHA256SUMS` covers `scripts/`, `backends/`, and `config/`. The outer USB/NAS `./restore` is hashed against `scripts/restore`. `omaclone install` will not put a kit copy on PATH or symlink the bar plugin to the stick.
- Restore stages under `~/.local/share/omaclone/restore-staging` (not tmpfs). `--delete` honors `config/excludes.txt` and will not unlink the plugin tree. `etc.tar` is extracted with a path allowlist; `ld.so.preload` / `profile.d` / `modprobe.d` are refused. Identity pacman uses native packages only (`pacman -Qqen`). `--blank-omarchy` requires `OMACLONE_TEST=1`.
- Proton Pass and 1Password CLIs must already be on PATH. Omaclone does not download or `eval` vendor installers (marketplace `curl-pipe-shell`).
- User timers use a finite timeout (`6h` clone, `2h` prune), `NoNewPrivileges`, and `PrivateTmp`. Interactive sudo goes through `/dev/tty` with a FIDO reminder (not the Omaclone keyring).
- Bar status keeps the last good snapshot on empty helper stdout; location id must match before JSON is applied. FileView watches disk UUID nodes only. Destination edits take a `flock` so status cannot clobber setup.
- NFS/CIFS/disk mountpoints are canonicalized before the denylist (`/mnt/../../etc` is refused). Disk UUIDs must match `[0-9a-fA-F-]{8,36}` (no `../`). SFTP uses `ssh --` and rejects option-like usernames (`-oProxyCommand`). NFS URIs reject commas, like CIFS.
- S3/cloud locations show a clone count from the last clone/prune (cached in `repo-stats-<id>.json`). Status does not list the bucket on every bar refresh, so it does not add S3 LIST/GET charges. Until a clone has run on this machine the tile stays a dash.
- Setup is one question per screen. A one-line hint sits on the field it applies to (NFS Mapall, AWS IAM → README), rendered as plain gum text — not markdown cards stacked above the next picker. Full IAM JSON, Mapall walkthrough, and S3 restore details stay in the README.
- Extra disk: USB/hotplug defaults to `udisksctl` (mount while cloning). A chosen path such as `/mnt/external-NVMe` is mounted during setup; sudo uses `/dev/tty` so gum does not steal the prompt. If that mount fails, udisks is used and setup continues (no “not ready” retry loop). Removable disks stay cold unless a systemd mount is opted in. Setup shows the mount error instead of swallowing it. `findmnt` miss on an unmounted disk no longer aborts `mount` under `pipefail`. The picker skips EFI, BIOS-boot, MSR, and sub-1G partitions when a larger volume exists, and sorts unmounted removable first. Clones always go in `<mount>/omaclone/` even if a leftover `repo/` sits at the volume root. FAT/exFAT/NTFS hot mounts set `uid`/`gid` so the kit is writable. Disk/CIFS `uid=` uses `command id` so the backend `id` verb cannot shadow it. Discover ignores `autofs` fstype so an NFS kit is not labeled `disk`.
- NFS `ready` requires a live `nfs`/`nfs4` mount (not idle autofs). Automount units include `nconnect=8,nosuid,nodev,noexec,proto=tcp`; `omaclone install` upgrades existing units and remounts hardening flags. CIFS setup probes the share before saving. `local` refuses an unmounted `/mnt` path and no longer defaults to `$HOME/Backups`. SFTP location JSON is offline when SSH is unreachable. `omaclone location --json` works. Kit `./restore` does not install `nfs-utils` when transport is empty. `omaclone copy` wakes/mounts the destination share. Clone excludes a restic repo that lives under `$HOME`.
- Security: restic password is sealed on an unlinked `/dev/fd/N` (not a named `/dev/shm` file in `ps`). Clone errors no longer copy restic stderr into last-result, notify-send, or the bar. Kit `SHA256SUMS` covers scripts and backends; kit `config.toml` drops secret-looking keys. `sudo prep.sh` is gone (user prep + `sudo tar` for `/etc` only). Extra-disk mounts are `nosuid,nodev,noexec`.
- Clone and restore are covered by a hermetic restic round-trip and a `--cron` skip matrix (`make test`, GitHub Actions). S3 is covered by URL/credential unit tests and a MinIO restic round-trip.
- Unlocking the Omaclone keyring uses a Secret Service *plain* session (raw password bytes). The previous DH-encrypted session made a correct password look invalid. The prompt distinguishes the keyring collection password from the restic repository password. `omaclone setup secrets` can recreate the collection if that keyring password was never chosen.
- S3 setup is per provider (restic + vendor docs): AWS regional endpoint and required region; R2 account id / jurisdiction / region `auto`; Wasabi region service URLs; B2 S3 endpoint from the bucket page; MinIO HTTP(S). Keys are verified with a signed ListObjects probe before `restic init`. Access key is the AKIA/ASIA key id, not an IAM role ARN (optional assume-role ARN is a separate prompt). ASIA keys require a session token. Ambient `~/.aws` credentials and EC2 IMDS cannot override the stored keys.
- AWS S3 setup requires the bucket region and uses `s3.<region>.amazonaws.com`. A blank region was signed as us-east-1, which AWS reports as Access Denied even with valid keys. restic is passed `-o s3.region` and `AWS_REGION`.
- Adding AWS/S3 as a second location is independent of NAS: leftover NFS uri/mount/vendor are not copied, bar status no longer rewrites in-progress cloud setup back onto the NAS location, and the pane lists it as Cloud / AWS S3 rather than NAS.
- Switching locations in the bar pane takes on the first click. The helper does not `stat` idle NFS/CIFS automounts (that hang was reported as “Status helper failed” on S3→NAS), and `omaclone status` cannot rewrite NAS over an in-progress S3 switch (atomic `location_apply_transport` plus the destination lock).
- MinIO / custom S3 endpoints can use HTTP (`transport.tls=0`). AWS, R2, Wasabi, and B2 stay HTTPS.
- S3 `pre-restic` keeps `$NAS_BACKUP_ENVFILE` so AWS keys actually reach restic. Backend processes do not shred that file on exit.
- Failed S3 credentials are a password skip (warning chip), not a green “not mounted”.
- `pre-restic` failures abort; restic is not run without AWS keys.
- USB/discovered locations keep a real name (volume label or `USB`), not `Discovered Omaclone`. Import does not overwrite a name you already chose.
- Unplugged USB is not a warning. Other warnings can be dismissed from the pane.
- Forgetting a location, or **Abandon this destination**, keeps other locations and the password source. **Erase all Omaclone settings** requires a default-off confirmation and typing `ERASE SETTINGS`. Clone data on disk is not deleted.
- Extra disks with a mountpoint can enable the daily timer (`omaclone location schedule on|off`). USB/cold stays off by default.
- Daily clones install timer units even if the PATH symlink already exists. Uninstall removes Super+Space keys we added.
- Restore requires typing `RESTORE` (unless `--blank-omarchy`), verifies with restic, overlays by default, and needs `REPLACE` for `--delete`.
- Kit `./restore` prefers a git-installed plugin and checks `SHA256SUMS`.
- `/etc` restore refuses systemd, pam, polkit, ssh, ssl, and cron even if the allowlist is edited.
- CIFS UNC is validated; NFS/CIFS/disk mounts use `nosuid,nodev,noexec`. SFTP uses `StrictHostKeyChecking=yes`.
- First-run pane is a setup door, not a warning shotgun. Widening the keep plan does not prune.
- Identity clone includes ssh/gpg/browsers; Flatpak Steam is excluded. `omaclone --version` prints the `manifest.json` version.
- CLI split into `cmd-setup.sh` / `cmd-clone.sh` / `cmd-restore.sh` / `cmd-status.sh`. Pane rows live in `ActionRow.qml`, `LocationRadio.qml`, `KeepPlan.qml`.
- `omaclone verify` (`restic check --read-data-subset=1/10`), `omaclone estimate`, and `omaclone copy [ID]` to another mounted location.
- First-clone setup shows a size estimate. `OMACLONE_*` env vars are canonical aliases for `NAS_BACKUP_*`.
- CI runs `python3 -m py_compile` and shellcheck errors.
