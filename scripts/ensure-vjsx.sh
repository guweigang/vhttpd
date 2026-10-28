#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/ci/toolchain.env"
destination="${VJSX_DIR:-$root/.deps/vjsx}"
if [[ ! -e "$destination" && ! -L "$destination" ]]; then
  mkdir -p "$(dirname "$destination")"
  lock="$destination.fetch-lock"
  if ! mkdir "$lock" 2>/dev/null; then
    echo "Another process is preparing $destination; retry after it finishes." >&2
    exit 1
  fi
  temporary="$(mktemp -d "$(dirname "$destination")/.vjsx-fetch.XXXXXX")"
  trap 'rm -rf "$temporary"; rmdir "$lock"' EXIT
  if [[ -e "$destination" || -L "$destination" ]]; then
    echo "Dependency destination appeared during preparation: $destination" >&2
    exit 1
  fi
  git init -q "$temporary"
  git -C "$temporary" remote add origin "$VJSX_REPO"
  git -C "$temporary" fetch --depth 1 origin "$VJSX_COMMIT"
  git -C "$temporary" checkout -q --detach FETCH_HEAD
  mv "$temporary" "$destination"
fi
actual="$(git -C "$destination" rev-parse HEAD)"
if [[ "$actual" != "$VJSX_COMMIT" ]]; then
  echo "vjsx must be pinned to $VJSX_COMMIT; refusing to change $destination ($actual)." >&2
  exit 1
fi
if [[ -n "$(git -C "$destination" status --porcelain --untracked-files=normal)" ]]; then
  echo "vjsx has unpublished source changes: $destination. Commit them and update the dependency lock before building." >&2
  exit 1
fi
printf '%s\n' "$destination"
