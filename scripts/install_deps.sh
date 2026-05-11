#!/usr/bin/env bash
set -euo pipefail

mode="${1:-core}"
repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

os_name="$(uname -s)"
home_vmodules="${HOME}/.vmodules"
vjsx_dir="${home_vmodules}/vjsx"
local_quickjs_dir=$(CDPATH= cd -- "${repo_root}/../quickjs" 2>/dev/null && pwd || true)

log() {
  printf '[deps] %s\n' "$*"
}

fail() {
  printf '[deps] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

is_quickjs_ng_checkout() {
  [ -n "$1" ] &&
    [ -f "$1/quickjs.c" ] &&
    [ -f "$1/quickjs-c-atomics.h" ] &&
    grep -q 'QJS_VERSION_MAJOR' "$1/quickjs.h" 2>/dev/null
}

brew_install_if_missing() {
  local formula="$1"
  if brew list --formula "$formula" >/dev/null 2>&1; then
    return
  fi
  brew install "$formula"
}

apt_install() {
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update
    apt-get install -y --no-install-recommends "$@"
  else
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "$@"
  fi
}

install_core_packages() {
  case "$os_name" in
    Darwin)
      need_cmd brew
      brew_install_if_missing bdw-gc
      brew_install_if_missing libpq
      brew_install_if_missing mysql-client
      brew_install_if_missing openssl@3
      brew_install_if_missing pkg-config
      brew_install_if_missing sqlite
      brew_install_if_missing git
      brew_install_if_missing curl
      brew_install_if_missing unzip
      ;;
    Linux)
      need_cmd apt-get
      apt_install \
        build-essential \
        ca-certificates \
        curl \
        default-libmysqlclient-dev \
        git \
        libgc-dev \
        libpq-dev \
        libsqlite3-dev \
        libssl-dev \
        pkg-config \
        sqlite3 \
        unzip
      ;;
    *)
      fail "unsupported OS: ${os_name}"
      ;;
  esac
}

ensure_vjsx_checkout() {
  mkdir -p "$home_vmodules"
  if [ -L "$vjsx_dir" ]; then
    log "using existing vjsx symlink: ${vjsx_dir}"
    return
  fi
  if [ -d "$vjsx_dir/.git" ]; then
    log "using existing vjsx checkout: ${vjsx_dir}"
    return
  fi
  if [ -e "$vjsx_dir" ]; then
    fail "path exists but is not a vjsx checkout or symlink: ${vjsx_dir}"
  fi
  need_cmd git
  log "cloning guweigang/vjsx into ${vjsx_dir}"
  git clone --depth=1 https://github.com/guweigang/vjsx "$vjsx_dir"
}

ensure_vjsx_quickjs_source() {
  ensure_vjsx_checkout
  need_cmd git
  [ -x "${vjsx_dir}/scripts/ensure-quickjs.sh" ] || fail "missing ${vjsx_dir}/scripts/ensure-quickjs.sh"
  if is_quickjs_ng_checkout "$local_quickjs_dir"; then
    log "using local QuickJS source at ${local_quickjs_dir}"
    return
  fi
  log "ensuring vjsx managed QuickJS source"
  quickjs_path="$(VJS_QUICKJS_WORK_ROOT="$repo_root" "${vjsx_dir}/scripts/ensure-quickjs.sh")"
  log "using QuickJS source at ${quickjs_path}"
}

case "$mode" in
  core)
    install_core_packages
    ;;
  vjsx)
    install_core_packages
    ensure_vjsx_quickjs_source
    ;;
  db)
    install_core_packages
    ;;
  full)
    install_core_packages
    ensure_vjsx_quickjs_source
    ;;
  *)
    fail "unknown mode: ${mode} (expected: core | vjsx | db | full)"
    ;;
esac

log "done: ${mode}"
