#!/usr/bin/env bash
set -euo pipefail

bin_path="${1:-./vhttpd}"
os_name="$(uname -s)"
share_root="${VHTTPD_SHARE_ROOT:-/usr/local/share/vhttpd}"
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

has_vjsx_runtime_assets() {
  local root="$1"
  [ -n "$root" ] && [ -f "$root/web/js/buffer.js" ]
}

resolve_vjsx_asset_root() {
  local bin_dir
  bin_dir="$(CDPATH= cd -- "$(dirname -- "$bin_path")" && pwd)"
  local candidate
  for candidate in \
    "$vjsx_asset_root_override" \
    "$bin_dir/runtime/vjsx" \
    "$bin_dir/../runtime/vjsx" \
    "$share_root/vjsx" \
    "$HOME/.vmodules/vjsx"
  do
    if has_vjsx_runtime_assets "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
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
        if [ -e "$dep_path" ]; then
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
else
  warn "command mysql_config is absent; MySQL client environments may be incomplete"
fi

if command -v pg_config >/dev/null 2>&1; then
  ok "command pg_config"
else
  warn "command pg_config is absent; PostgreSQL client environments may be incomplete"
fi

resolved_vjsx_asset_root="$(resolve_vjsx_asset_root || true)"
if [ -n "$resolved_vjsx_asset_root" ]; then
  ok "vjsx runtime assets ${resolved_vjsx_asset_root}"
else
  warn "vjsx runtime assets are unresolved; checked VJSX_ASSET_ROOT, bundle-relative runtime/vjsx, ${share_root}/vjsx, and ~/.vmodules/vjsx"
fi

if [ -L "${HOME}/.vmodules/vjsx" ]; then
  ok "vjsx compatibility symlink ${HOME}/.vmodules/vjsx"
else
  warn "vjsx compatibility symlink ${HOME}/.vmodules/vjsx is absent; this is optional when VJSX_ASSET_ROOT or bundled runtime/vjsx is used"
fi

if [ "$status" -ne 0 ]; then
  printf '[runtime-doctor] one or more runtime dependencies are unresolved\n' >&2
fi

exit "$status"
