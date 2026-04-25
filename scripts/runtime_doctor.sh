#!/usr/bin/env bash
set -euo pipefail

bin_path="${1:-./vhttpd}"
os_name="$(uname -s)"
vjsx_asset_root_override="${VJSX_ASSET_ROOT:-}"
status=0

ok() {
  printf '[runtime-doctor] ok: %s\n' "$*"
}

warn() {
  printf '[runtime-doctor] warn: %s\n' "$*"
}

bad() {
  printf '[runtime-doctor] missing: %s\n' "$*" >&2
  status=1
}

resolve_loader_path() {
  local dep_path="$1"
  local bin_dir
  bin_dir="$(CDPATH= cd -- "$(dirname -- "$bin_path")" && pwd)"
  case "$dep_path" in
    @loader_path/*)
      printf '%s\n' "${bin_dir}/${dep_path#@loader_path/}"
      ;;
    @executable_path/*)
      printf '%s\n' "${bin_dir}/${dep_path#@executable_path/}"
      ;;
    *)
      printf '%s\n' "$dep_path"
      ;;
  esac
}

[ -f "$bin_path" ] || {
  bad "binary ${bin_path}"
  exit 1
}

[ -x "$bin_path" ] || bad "executable bit on ${bin_path}"

case "$os_name" in
  Linux)
    if command -v ldd >/dev/null 2>&1; then
      deps_output="$(ldd "$bin_path" || true)"
      printf '%s\n' "$deps_output"
      if printf '%s\n' "$deps_output" | grep -q 'not found'; then
        bad "one or more linked libraries are unresolved"
      else
        ok "ldd reported no missing linked libraries"
      fi
    else
      warn "ldd is unavailable; skipping linked library resolution checks"
    fi
    ;;
  Darwin)
    if command -v otool >/dev/null 2>&1; then
      deps_output="$(otool -L "$bin_path")"
      printf '%s\n' "$deps_output"
      while IFS= read -r line; do
        dep_path="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')"
        case "$dep_path" in
          "${bin_path}:"|"$bin_path"|/usr/lib/*|/System/*|@rpath/*|'')
            continue
            ;;
        esac
        resolved_dep_path="$(resolve_loader_path "$dep_path")"
        if [ -e "$resolved_dep_path" ]; then
          ok "linked library ${dep_path}"
        else
          bad "linked library ${dep_path}"
        fi
      done <<EOF
$deps_output
EOF
    else
      warn "otool is unavailable; skipping linked library resolution checks"
    fi
    ;;
  *)
    warn "unsupported OS for linked library checks: ${os_name}"
    ;;
esac

if command -v sqlite3 >/dev/null 2>&1; then
  ok "command sqlite3"
else
  warn "command sqlite3 is absent; sqlite-backed workflows may be unavailable"
fi

if command -v mysql_config >/dev/null 2>&1; then
  ok "command mysql_config"
elif command -v mariadb_config >/dev/null 2>&1; then
  ok "command mariadb_config (MySQL client compatible)"
else
  warn "command mysql_config or mariadb_config is absent; MySQL/MariaDB client environments may be incomplete"
fi

if command -v pg_config >/dev/null 2>&1; then
  ok "command pg_config"
else
  warn "command pg_config is absent; PostgreSQL client environments may be incomplete"
fi

if [ -n "$vjsx_asset_root_override" ]; then
  ok "vjsx runtime asset override ${vjsx_asset_root_override}"
else
  ok "vjsx runtime assets are embedded; VJSX_ASSET_ROOT is unset"
fi

if [ -L "${HOME}/.vmodules/vjsx" ]; then
  warn "legacy vjsx compatibility symlink ${HOME}/.vmodules/vjsx is present but no longer required"
else
  ok "legacy vjsx compatibility symlink ${HOME}/.vmodules/vjsx is absent"
fi

if [ "$status" -ne 0 ]; then
  printf '[runtime-doctor] one or more runtime dependencies are unresolved\n' >&2
fi

exit "$status"
