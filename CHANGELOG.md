# Changelog

## 1.5.0

- Clone and restore are covered by a hermetic restic round-trip and a `--cron` skip matrix (`make test`, GitHub Actions).
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
