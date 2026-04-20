#!/usr/bin/env bash
set -euo pipefail

mode="${1:-core}"

os_name="$(uname -s)"
arch_name="$(uname -m)"
home_vmodules="${HOME}/.vmodules"
vjsx_dir="${home_vmodules}/vjsx"
quickjs_cache_dir="${HOME}/.cache/vhttpd/quickjs"

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

ensure_linux_quickjs_archive() {
  [ "$os_name" = "Linux" ] || return
  mkdir -p "${vjsx_dir}/libs" "$(dirname "$quickjs_cache_dir")"
  need_cmd git
  need_cmd make
  if [ ! -d "$quickjs_cache_dir/.git" ]; then
    log "cloning QuickJS into ${quickjs_cache_dir}"
    rm -rf "$quickjs_cache_dir"
    git clone --depth=1 https://github.com/bellard/quickjs "$quickjs_cache_dir"
  fi
  log "building QuickJS static archive"
  make -C "$quickjs_cache_dir" libquickjs.a
  cp "$quickjs_cache_dir/libquickjs.a" "${vjsx_dir}/libs/qjs_linux_x64.a"
  log "installed ${vjsx_dir}/libs/qjs_linux_x64.a"
}

ensure_vjsx_runtime_assets() {
  ensure_vjsx_checkout
  case "$os_name" in
    Darwin)
      case "$arch_name" in
        arm64)
          [ -f "${vjsx_dir}/libs/qjs_macos_arm64.a" ] || fail "missing ${vjsx_dir}/libs/qjs_macos_arm64.a"
          ;;
        x86_64)
          [ -f "${vjsx_dir}/libs/qjs_macos_x64.a" ] || fail "missing ${vjsx_dir}/libs/qjs_macos_x64.a"
          ;;
        *)
          fail "unsupported macOS arch: ${arch_name}"
          ;;
      esac
      ;;
    Linux)
      case "$arch_name" in
        x86_64|amd64)
          ensure_linux_quickjs_archive
          ;;
        *)
          fail "unsupported Linux arch for bundled QuickJS archive: ${arch_name}"
          ;;
      esac
      ;;
    *)
      fail "unsupported OS: ${os_name}"
      ;;
  esac
}

case "$mode" in
  core)
    install_core_packages
    ;;
  vjsx)
    install_core_packages
    ensure_vjsx_runtime_assets
    ;;
  db)
    install_core_packages
    ;;
  full)
    install_core_packages
    ensure_vjsx_runtime_assets
    ;;
  *)
    fail "unknown mode: ${mode} (expected: core | vjsx | db | full)"
    ;;
esac

log "done: ${mode}"
