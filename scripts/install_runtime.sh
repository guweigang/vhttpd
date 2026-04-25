#!/usr/bin/env bash
set -euo pipefail

profile="${1:-core}"
prefix="${VHTTPD_PREFIX:-$HOME/.local}"

os_name="$(uname -s)"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bundle_root="$(CDPATH= cd -- "${script_dir}/.." && pwd)"
src_bin="${bundle_root}/vhttpd"
src_runtime_libs="${bundle_root}/runtime/libs"

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

install_runtime_core_packages() {
  case "$os_name" in
    Darwin)
      log "bundled runtime libraries cover mysql / pgsql / openssl / boehm on macOS; skipping brew installs"
      ;;
    Linux)
      log "bundled runtime libraries cover mysql / pgsql / openssl / boehm on Linux; skipping apt installs"
      ;;
    *)
      fail "unsupported OS: ${os_name}"
      ;;
  esac
}

install_binary() {
  [ -f "$src_bin" ] || fail "expected bundled binary at ${src_bin}"
  mkdir -p "${prefix}/bin" "${prefix}/bin/runtime" "${prefix}/libexec/vhttpd"
  cp "$src_bin" "${prefix}/bin/vhttpd"
  chmod +x "${prefix}/bin/vhttpd"
  cp "${bundle_root}/scripts/runtime_doctor.sh" "${prefix}/libexec/vhttpd/runtime_doctor.sh"
  chmod +x "${prefix}/libexec/vhttpd/runtime_doctor.sh"
  log "installed ${prefix}/bin/vhttpd"
}

install_runtime_libs() {
  if [ ! -d "$src_runtime_libs" ]; then
    log "no bundled runtime libraries found; skipping ${prefix}/bin/runtime/libs"
    return
  fi
  rm -rf "${prefix}/bin/runtime/libs"
  mkdir -p "${prefix}/bin/runtime"
  cp -R "$src_runtime_libs" "${prefix}/bin/runtime/libs"
  log "installed bundled runtime libraries into ${prefix}/bin/runtime/libs"
}

case "$profile" in
  none)
    ;;
  core)
    install_runtime_core_packages
    ;;
  db|full)
    install_runtime_core_packages
    ;;
  *)
    fail "unknown profile: ${profile} (expected: none | core | db | full)"
    ;;
esac

install_binary
install_runtime_libs
"${prefix}/libexec/vhttpd/runtime_doctor.sh" "${prefix}/bin/vhttpd" || true

log "done: profile=${profile} prefix=${prefix}"
