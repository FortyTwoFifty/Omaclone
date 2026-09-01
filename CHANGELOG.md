# Changelog

## 1.5.0

- Extra disk: USB/hotplug defaults to `udisksctl` (mount while cloning). A chosen path such as `/mnt/external-NVMe` is mounted during setup; sudo uses `/dev/tty` so gum does not steal the prompt. If that mount fails, udisks is used and setup continues (no “not ready” retry loop). Removable disks stay cold unless a systemd mount is opted in. Setup shows the mount error instead of swallowing it. `findmnt` miss on an unmounted disk no longer aborts `mount` under `pipefail`. The picker skips EFI, BIOS-boot, MSR, and sub-1G partitions when a larger volume exists, and sorts unmounted removable first. Clones always go in `<mount>/omaclone/` even if a leftover `repo/` sits at the volume root. FAT/exFAT/NTFS hot mounts set `uid`/`gid` so the kit is writable. Disk/CIFS `uid=` uses `command id` so the backend `id` verb cannot shadow it. Discover ignores `autofs` fstype so an NFS kit is not labeled `disk`.
- NFS `ready` requires a live `nfs`/`nfs4` mount (not idle autofs). Automount units include `nconnect=8,nosuid,nodev,noexec,proto=tcp`; `omaclone install` upgrades existing units and remounts hardening flags. CIFS setup probes the share before saving. `local` refuses an unmounted `/mnt` path and no longer defaults to `$HOME/Backups`. SFTP location JSON is offline when SSH is unreachable. `omaclone location --json` works. Kit `./restore` does not install `nfs-utils` when transport is empty. `omaclone copy` wakes/mounts the destination share. Clone excludes a restic repo that lives under `$HOME`.
- Security: restic password is sealed on an unlinked `/dev/fd/N` (not a named `/dev/shm` file in `ps`). Clone errors no longer copy restic stderr into last-result, notify-send, or the bar. Kit `SHA256SUMS` covers scripts and backends; kit `config.toml` drops secret-looking keys. `sudo prep.sh` is gone (user prep + `sudo tar` for `/etc` only). Extra-disk mounts are `nosuid,nodev,noexec`.
- Clone and restore are covered by a hermetic restic round-trip and a `--cron` skip matrix (`make test`, GitHub Actions). S3 is covered by URL/credential unit tests and a MinIO restic round-trip.
- MinIO / custom S3 endpoints can use HTTP (`transport.tls=0`). AWS, R2, Wasabi, and B2 stay HTTPS.
- S3 `pre-restic` keeps `$NAS_BACKUP_ENVFILE` so AWS keys actually reach restic. Backend processes do not shred that file on exit.
- Failed S3 credentials are a password skip (warning chip), not a green “not mounted”.
- `pre-restic` failures abort; restic is not run without AWS keys.
- Setup **Start over** actually resets destination/secrets/locations. The restic repo on disk is not deleted.
- Extra disks with a mountpoint can enable the daily timer (`omaclone location schedule on|off`). USB/cold stays off by default.
- Daily clones install timer units even if the PATH symlink already exists. Uninstall removes Super+Space keys we added.
- Restore requires typing `RESTORE` (unless `--blank-omarchy`), verifies with restic, overlays by default, and needs `REPLACE` for `--delete`.
- Kit `./restore` prefers a git-installed plugin and checks `SHA256SUMS`.
- `/etc` restore refuses systemd, pam, polkit, ssh, ssl, and cron even if the allowlist is edited.
- CIFS UNC is validated; NFS/CIFS/disk mounts use `nosuid,nodev,noexec`. SFTP uses `StrictHostKeyChecking=yes`.
- First-run pane is a setup door, not a warning shotgun. Widening the keep plan does not prune.
- Identity clone includes ssh/gpg/browsers; Flatpak Steam is excluded. `omaclone --version` prints `1.5.0`.
- CLI split into `cmd-setup.sh` / `cmd-clone.sh` / `cmd-restore.sh` / `cmd-status.sh`. Pane rows live in `ActionRow.qml`, `LocationRadio.qml`, `KeepPlan.qml`.
- `omaclone verify` (`restic check --read-data-subset=1/10`), `omaclone estimate`, and `omaclone copy [ID]` to another mounted location.
- First-clone setup shows a size estimate. `OMACLONE_*` env vars are canonical aliases for `NAS_BACKUP_*`.
- CI runs `python3 -m py_compile` and shellcheck errors.
