#!/usr/bin/env bash
set -euo pipefail

os_name="$(uname -s)"
arch_name="$(uname -m)"
home_vmodules="${HOME}/.vmodules"
vjsx_dir="${home_vmodules}/vjsx"

status=0

ok() {
  printf '[doctor] ok: %s\n' "$*"
}

warn() {
  printf '[doctor] warn: %s\n' "$*"
}

bad() {
  printf '[doctor] missing: %s\n' "$*" >&2
  status=1
}

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "command ${cmd}"
  else
    bad "command ${cmd}"
  fi
}

check_file() {
  local file_path="$1"
  if [ -f "$file_path" ]; then
    ok "file ${file_path}"
  else
    bad "file ${file_path}"
  fi
}

check_macos_archive_arch() {
  local file_path="$1"
  local expected_arch="$2"
  if ! command -v lipo >/dev/null 2>&1; then
    warn "lipo is unavailable; skipping architecture check for ${file_path}"
    return
  fi
  if lipo -info "$file_path" 2>/dev/null | grep -q "architecture: ${expected_arch}"; then
    ok "archive ${file_path} has architecture ${expected_arch}"
  else
    bad "archive ${file_path} does not match architecture ${expected_arch}"
  fi
}

check_pkg() {
  local pkg_name="$1"
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "$pkg_name"; then
    ok "pkg-config ${pkg_name}"
  else
    bad "pkg-config ${pkg_name}"
  fi
}

check_cmd v
check_cmd pkg-config
check_pkg openssl
check_pkg bdw-gc

if [ -e "$vjsx_dir" ]; then
  ok "vjsx module path ${vjsx_dir}"
else
  warn "vjsx module path ${vjsx_dir} is absent; run ./scripts/install_deps.sh vjsx if you need embedded runtime support"
fi

if [ -e "$vjsx_dir" ]; then
  case "$os_name" in
    Darwin)
      case "$arch_name" in
        arm64)
          check_file "${vjsx_dir}/libs/qjs_macos_arm64.a"
          check_macos_archive_arch "${vjsx_dir}/libs/qjs_macos_arm64.a" "arm64"
          ;;
        x86_64)
          check_file "${vjsx_dir}/libs/qjs_macos_x64.a"
          check_macos_archive_arch "${vjsx_dir}/libs/qjs_macos_x64.a" "x86_64"
          ;;
        *)
          warn "unsupported macOS arch for vjsx quickjs archive checks: ${arch_name}"
          ;;
      esac
      ;;
    Linux)
      case "$arch_name" in
        x86_64|amd64)
          check_file "${vjsx_dir}/libs/qjs_linux_x64.a"
          ;;
        *)
          warn "unsupported Linux arch for vjsx quickjs archive checks: ${arch_name}"
          ;;
      esac
      ;;
    *)
      warn "unsupported OS for vjsx quickjs archive checks: ${os_name}"
      ;;
  esac
fi

if command -v sqlite3 >/dev/null 2>&1; then
  ok "command sqlite3"
else
  warn "command sqlite3 (needed for db profile checks and local sqlite usage)"
fi

if command -v mysql_config >/dev/null 2>&1; then
  ok "command mysql_config"
elif command -v mariadb_config >/dev/null 2>&1; then
  ok "command mariadb_config (MySQL client compatible)"
else
  warn "command mysql_config or mariadb_config (needed when building WITH_DB=1 against MySQL/MariaDB client libs)"
fi

if command -v pg_config >/dev/null 2>&1; then
  ok "command pg_config"
else
  warn "command pg_config (needed when building WITH_DB=1 against PostgreSQL client libs)"
fi

if [ "$status" -ne 0 ]; then
  printf '[doctor] one or more required build dependencies are missing\n' >&2
fi

exit "$status"
