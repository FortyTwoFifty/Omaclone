#!/usr/bin/env bash
# Sourced library — not a standalone entrypoint.
set +o history 2>/dev/null || true
unset HISTFILE
set +x +v
set -euo pipefail

if [[ -n "${OMACLONE_DEPS_LOADED:-}" ]]; then
  return 0
fi
OMACLONE_DEPS_LOADED=1

if ! declare -F die >/dev/null 2>&1; then
  die() { printf 'omaclone: %s\n' "$*" >&2; exit 1; }
fi

_CORE_PACMAN_PKGS=(gum jq restic rsync curl)

_deps_pacman() {
  if [[ -n "${OMACLONE_PACMAN:-}" ]]; then
    # Test hook: a stub command that receives the same argv as pacman.
    # shellcheck disable=SC2086
    command ${OMACLONE_PACMAN} "$@"
    return
  fi
  if declare -F sudo_tty >/dev/null 2>&1; then
    printf '%s\n' "Installing packages with sudo — touch your FIDO key if prompted. This is not the Omaclone keyring." >&2
    sudo_tty pacman "$@"
  else
    sudo pacman "$@"
  fi
}

deps_ensure_pacman() {
  local pkg="$1"
  local cmd="${2:-$pkg}"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing $pkg …" >&2
  _deps_pacman -S --needed --noconfirm "$pkg" || {
    die "failed to install $pkg via pacman — re-run: omaclone setup"
  }
}

deps_ensure_pacman_list() {
  local missing=() pkg
  for pkg in "$@"; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  echo "Installing ${missing[*]} …" >&2
  _deps_pacman -S --needed --noconfirm "${missing[@]}" || {
    die "failed to install packages — re-run: omaclone setup"
  }
}

deps_ensure_core() {
  deps_ensure_pacman_list "${_CORE_PACMAN_PKGS[@]}"
}

deps_curl_install() {
  local label="$1"
  # Marketplace listing forbids download-then-eval of vendor install.sh.
  # Omaclone never runs a remote installer; put the CLI on PATH yourself.
  echo "Omaclone does not download or run the $label installer." >&2
  echo "Install $label from the vendor, then re-run: omaclone setup" >&2
  return 1
}

_deps_arch_map() {
  case "$(uname -m)" in
    x86_64) printf '%s\n' "amd64" ;;
    aarch64|aarch64_be) printf '%s\n' "arm64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}
