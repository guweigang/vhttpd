#!/usr/bin/env bash
set -euo pipefail

profile="${1:-core}"
prefix="${VHTTPD_PREFIX:-$HOME/.local}"
share_root="${VHTTPD_SHARE_ROOT:-/usr/local/share/vhttpd}"

os_name="$(uname -s)"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bundle_root="$(CDPATH= cd -- "${script_dir}/.." && pwd)"
src_bin="${bundle_root}/vhttpd"
src_vjsx_runtime="${bundle_root}/runtime/vjsx"

log() {
  printf '[install-runtime] %s\n' "$*"
}

fail() {
  printf '[install-runtime] error: %s\n' "$*" >&2
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

copy_dir_to_stable_path() {
  local src="$1"
  local dst="$2"
  local dst_parent
  dst_parent="$(dirname "$dst")"
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$dst_parent"
    rm -rf "$dst"
    cp -R "$src" "$dst"
  else
    sudo mkdir -p "$dst_parent"
    sudo rm -rf "$dst"
    sudo cp -R "$src" "$dst"
    sudo chown -R "$(id -u):$(id -g)" "$dst"
  fi
}

install_runtime_core_packages() {
  case "$os_name" in
    Darwin)
      need_cmd brew
      brew_install_if_missing bdw-gc
      brew_install_if_missing openssl@3
      ;;
    Linux)
      need_cmd apt-get
      # Install runtime libs directly when package names are stable.
      # libgc-dev is used here instead of a narrower runtime package to keep distro variance low.
      apt_install libgc-dev libssl-dev sqlite3 libsqlite3-dev
      ;;
    *)
      fail "unsupported OS: ${os_name}"
      ;;
  esac
}

install_runtime_db_packages() {
  case "$os_name" in
    Darwin)
      need_cmd brew
      brew_install_if_missing sqlite
      brew_install_if_missing mysql-client
      brew_install_if_missing libpq
      ;;
    Linux)
      need_cmd apt-get
      # Use dev packages here so build and runtime users get the same linker surface.
      apt_install default-libmysqlclient-dev libpq-dev libsqlite3-dev sqlite3
      ;;
    *)
      fail "unsupported OS: ${os_name}"
      ;;
  esac
}

install_binary() {
  [ -f "$src_bin" ] || fail "expected bundled binary at ${src_bin}"
  mkdir -p "${prefix}/bin" "${prefix}/libexec/vhttpd"
  cp "$src_bin" "${prefix}/bin/vhttpd"
  chmod +x "${prefix}/bin/vhttpd"
  cp "${bundle_root}/scripts/runtime_doctor.sh" "${prefix}/libexec/vhttpd/runtime_doctor.sh"
  chmod +x "${prefix}/libexec/vhttpd/runtime_doctor.sh"
  log "installed ${prefix}/bin/vhttpd"
}

install_runtime_assets() {
  if [ ! -d "$src_vjsx_runtime" ]; then
    log "no bundled vjsx runtime assets found; skipping ${share_root}/vjsx"
    return
  fi
  copy_dir_to_stable_path "$src_vjsx_runtime" "${share_root}/vjsx"
  log "installed ${share_root}/vjsx"
}

case "$profile" in
  none)
    ;;
  core)
    install_runtime_core_packages
    ;;
  db|full)
    install_runtime_core_packages
    install_runtime_db_packages
    ;;
  *)
    fail "unknown profile: ${profile} (expected: none | core | db | full)"
    ;;
esac

install_binary
install_runtime_assets
"${prefix}/libexec/vhttpd/runtime_doctor.sh" "${prefix}/bin/vhttpd" || true

log "done: profile=${profile} prefix=${prefix}"
