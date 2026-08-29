#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

HOME_DIR=$(mktemp -d)
trap 'rm -rf "$HOME_DIR"' EXIT
export HOME="$HOME_DIR"
export XDG_CONFIG_HOME="$HOME_DIR/.config"
export XDG_DATA_HOME="$HOME_DIR/.local/share"
export NAS_BACKUP_ROOT="$ROOT"
export NAS_BACKUP_USER_CONFIG_DIR="$HOME_DIR/.config/omaclone"
export NAS_BACKUP_STATE_DIR="$HOME_DIR/.local/share/omaclone"
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
export OMACLONE_SKIP_SYSTEMD=1
unset NAS_BACKUP_LIB_LOADED OMACLONE_LOCATIONS_LOADED

source "$ROOT/scripts/lib.sh"

export OMACLONE_PLUGIN_DIR="$ROOT"
omaclone_link_plugin
[[ ! -L "$ROOT/omaclone.plugin" ]] || fail "nested self-symlink inside plugin tree"
[[ -d "$ROOT" && ! -L "$ROOT" ]] || fail "plugin root became a symlink"
unset OMACLONE_PLUGIN_DIR

clone=$(mktemp -d)
mkdir -p "$clone/omaclone.plugin"
echo keep >"$clone/omaclone.plugin/keep"
export OMACLONE_PLUGIN_DIR="$clone/omaclone.plugin"
omaclone_link_plugin >/dev/null 2>&1
[[ -f "$clone/omaclone.plugin/keep" ]] || fail "replaced an existing plugin clone"
[[ ! -L "$clone/omaclone.plugin" ]] || fail "turned an existing clone into a symlink"
[[ ! -L "$clone/omaclone.plugin/omaclone.plugin" ]] || fail "nested symlink in existing clone"
unset OMACLONE_PLUGIN_DIR
rm -rf "$clone"

export OMACLONE_PLUGIN_DIR="$HOME_DIR/.config/omarchy/plugins/omaclone.plugin"
omaclone_link_plugin
[[ -L "$OMACLONE_PLUGIN_DIR" ]] || fail "dev install should symlink the plugin dir"
[[ "$(readlink -f "$OMACLONE_PLUGIN_DIR")" == "$(readlink -f "$ROOT")" ]] \
  || fail "plugin symlink target: $(readlink -f "$OMACLONE_PLUGIN_DIR")"

omaclone_link_cli
[[ -L "$HOME/.local/bin/omaclone" ]] || fail "missing omaclone PATH symlink"
[[ -L "$HOME/.local/bin/omarchy-backup" ]] || fail "missing omarchy-backup alias"
[[ -L "$HOME/.local/bin/nas-backup" ]] || fail "missing nas-backup alias"
[[ "$(readlink -f "$HOME/.local/bin/omaclone")" == "$(readlink -f "$ROOT/scripts/omaclone")" ]] \
  || fail "omaclone PATH target"

echo foreign >"$HOME/.local/bin/keep-me"
omaclone_unlink_cli
omaclone_unlink_plugin
[[ ! -e "$HOME/.local/bin/omaclone" ]] || fail "uninstall left omaclone"
[[ ! -e "$HOME/.local/bin/omarchy-backup" ]] || fail "uninstall left omarchy-backup"
[[ ! -e "$HOME/.local/bin/nas-backup" ]] || fail "uninstall left nas-backup"
[[ ! -e "$OMACLONE_PLUGIN_DIR" ]] || fail "uninstall left plugin symlink"
[[ -f "$HOME/.local/bin/keep-me" ]] || fail "uninstall removed an unrelated file"
unset OMACLONE_PLUGIN_DIR

"$ROOT/scripts/omaclone" install >/dev/null 2>&1
[[ -L "$HOME/.local/bin/omaclone" ]] || fail "omaclone install did not create PATH command"
[[ -L "$HOME/.config/omarchy/plugins/omaclone.plugin" ]] \
  || fail "omaclone install did not symlink the plugin"
[[ "$(readlink -f "$HOME/.config/omarchy/plugins/omaclone.plugin")" == "$(readlink -f "$ROOT")" ]] \
  || fail "omaclone install plugin target"
menu="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
[[ -f "$menu" ]] || fail "omaclone install did not write the Omarchy menu extension"
grep -q '"omaclone"' "$menu" || fail "menu missing omaclone entries"

"$ROOT/scripts/omaclone" uninstall >/dev/null 2>&1
[[ ! -e "$HOME/.local/bin/omaclone" ]] || fail "omaclone uninstall left PATH command"
[[ ! -e "$HOME/.config/omarchy/plugins/omaclone.plugin" ]] \
  || fail "omaclone uninstall left plugin symlink"

mkdir -p "$HOME/.config/omarchy/plugins/omaclone.plugin"
echo clone >"$HOME/.config/omarchy/plugins/omaclone.plugin/manifest.json"
"$ROOT/scripts/omaclone" uninstall >/dev/null 2>&1
[[ -f "$HOME/.config/omarchy/plugins/omaclone.plugin/manifest.json" ]] \
  || fail "uninstall deleted a git-clone plugin folder"

ext="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$ext")"
printf '%s\n' '{"setup.keep":{"label":"Keep me"},"omaclone":{"label":"User label"}}' >"$ext"
omaclone_install_menu
python3 - "$ext" <<'PY' || fail "menu merge python"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["setup.keep"]["label"] == "Keep me", d
assert d["omaclone"]["label"] == "User label", d
assert "omaclone.clone" in d, d
PY

etc_rel_ok fido2 || fail "fido2 should be allowed"
etc_rel_ok fstab && fail "fstab must be refused"
etc_rel_ok crypttab && fail "crypttab must be refused"
etc_rel_ok hostname && fail "hostname must be refused"
etc_rel_ok ../fstab && fail "path traversal must be refused"
etc_rel_ok /etc/fido2 && fail "absolute path must be refused"
etc_rel_ok NetworkManager/system-connections && fail "NetworkManager must be refused"

echo "OK"
