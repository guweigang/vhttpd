#!/usr/bin/env bash
set -euo pipefail

bin_path="${1:-./vhttpd}"
runtime_dir="${2:-./runtime/libs}"
os_name="$(uname -s)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/vhttpd-bundle.XXXXXX")"
seen_file="${tmp_root}/seen.txt"
mapping_file="${tmp_root}/mapping.txt"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

log() {
  printf '[bundle-runtime-libs] %s\n' "$*"
}

fail() {
  printf '[bundle-runtime-libs] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

should_bundle_dependency() {
  local path="$1"
  local base
  base="$(basename "$path")"
  case "$base" in
    libmysqlclient.*|libmariadb.*|libpq.*|libssl.*|libcrypto.*|libgc.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mark_seen() {
  printf '%s\n' "$1" >> "$seen_file"
}

is_seen() {
  [ -f "$seen_file" ] && grep -Fqx "$1" "$seen_file"
}

record_mapping() {
  printf '%s\t%s\n' "$1" "$2" >> "$mapping_file"
}

lookup_staged_path() {
  [ -f "$mapping_file" ] || return 1
  awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$mapping_file"
}

mapping_count() {
  [ -f "$mapping_file" ] || {
    printf '0\n'
    return 0
  }
  wc -l < "$mapping_file" | tr -d ' '
}

list_deps() {
  local target="$1"
  case "$os_name" in
    Darwin)
      otool -L "$target" | awk 'NR > 1 {print $1}'
      ;;
    Linux)
      ldd "$target" | awk '/=>/ && $3 ~ /^\// {print $3}'
      ;;
    *)
      fail "unsupported OS: ${os_name}"
      ;;
  esac
}

copy_dependency_tree() {
  local target="$1"
  local dep
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    [ -f "$dep" ] || continue
    if ! should_bundle_dependency "$dep"; then
      continue
    fi
    if is_seen "$dep"; then
      continue
    fi
    mark_seen "$dep"
    mkdir -p "$runtime_dir"
    staged_path="$runtime_dir/$(basename "$dep")"
    if [ ! -f "$staged_path" ]; then
      cp "$dep" "$staged_path"
      log "bundled $(basename "$dep")"
    else
      log "reused $(basename "$dep")"
    fi
    record_mapping "$dep" "$staged_path"
    copy_dependency_tree "$dep"
  done < <(list_deps "$target")
}

rewrite_macos_binary() {
  local source_path="$1"
  local staged_path="$2"
  install_name_tool -change "$source_path" "@loader_path/runtime/libs/$(basename "$staged_path")" "$bin_path"
}

rewrite_macos_staged_lib() {
  local staged_lib="$1"
  local dep
  local dep_staged_path
  install_name_tool -id "@loader_path/$(basename "$staged_lib")" "$staged_lib"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    dep_staged_path="$(lookup_staged_path "$dep" || true)"
    if [ -n "$dep_staged_path" ]; then
      install_name_tool -change "$dep" "@loader_path/$(basename "$dep_staged_path")" "$staged_lib"
    fi
  done < <(list_deps "$staged_lib")
}

rewrite_linux_rpaths() {
  local staged_lib
  need_cmd patchelf
  patchelf --set-rpath '$ORIGIN/runtime/libs' "$bin_path"
  for staged_lib in "$runtime_dir"/*; do
    [ -f "$staged_lib" ] || continue
    patchelf --set-rpath '$ORIGIN' "$staged_lib"
  done
}

[ -f "$bin_path" ] || fail "binary not found: ${bin_path}"

case "$os_name" in
  Darwin)
    need_cmd otool
    need_cmd install_name_tool
    ;;
  Linux)
    need_cmd ldd
    need_cmd patchelf
    ;;
esac

mkdir -p "$runtime_dir"
copy_dependency_tree "$bin_path"

if [ "$(mapping_count)" -eq 0 ]; then
  log "no runtime libraries selected for bundling"
  exit 0
fi

case "$os_name" in
  Darwin)
    while IFS=$'\t' read -r source_path staged_path; do
      [ -n "$source_path" ] || continue
      rewrite_macos_binary "$source_path" "$staged_path"
    done < "$mapping_file"
    for staged_lib in "$runtime_dir"/*; do
      [ -f "$staged_lib" ] || continue
      rewrite_macos_staged_lib "$staged_lib"
    done
    ;;
  Linux)
    rewrite_linux_rpaths
    ;;
esac

log "done: $(find "$runtime_dir" -type f | wc -l | tr -d ' ') bundled libraries"
