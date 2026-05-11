#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
home_vmodules="${HOME}/.vmodules"
vjsx_dir="${home_vmodules}/vjsx"
local_quickjs_dir=$(CDPATH= cd -- "${repo_root}/../quickjs" 2>/dev/null && pwd || true)

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

check_pkg() {
  local pkg_name="$1"
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "$pkg_name"; then
    ok "pkg-config ${pkg_name}"
  else
    bad "pkg-config ${pkg_name}"
  fi
}

is_quickjs_ng_checkout() {
  [ -n "$1" ] &&
    [ -f "$1/quickjs.c" ] &&
    [ -f "$1/quickjs-c-atomics.h" ] &&
    grep -q 'QJS_VERSION_MAJOR' "$1/quickjs.h" 2>/dev/null
}

check_cmd v
check_cmd pkg-config
check_pkg openssl
check_pkg bdw-gc

if [ -e "$vjsx_dir" ]; then
  ok "vjsx build module path ${vjsx_dir}"
else
  warn "vjsx build module path ${vjsx_dir} is absent; run ./scripts/install_deps.sh vjsx before building embedded runtime support"
fi

if [ -e "$vjsx_dir" ]; then
  if [ -x "${vjsx_dir}/scripts/ensure-quickjs.sh" ]; then
    ok "vjsx QuickJS ensure script"
    if is_quickjs_ng_checkout "$local_quickjs_dir"; then
      quickjs_path="$local_quickjs_dir"
    elif quickjs_path="$(VJS_QUICKJS_WORK_ROOT="$repo_root" "${vjsx_dir}/scripts/ensure-quickjs.sh")"; then
      :
    else
      bad "managed QuickJS source"
      quickjs_path=""
    fi
    if [ -n "$quickjs_path" ]; then
      if [ -f "${quickjs_path}/quickjs.c" ] && [ -f "${quickjs_path}/quickjs.h" ]; then
        ok "managed QuickJS source ${quickjs_path}"
      else
        bad "managed QuickJS source ${quickjs_path}"
      fi
    fi
  else
    bad "vjsx QuickJS ensure script ${vjsx_dir}/scripts/ensure-quickjs.sh"
  fi
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
