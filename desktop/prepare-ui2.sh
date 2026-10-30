#!/usr/bin/env bash
set -euo pipefail
# Apply reviewed compiler/input workarounds only to a build-local copy.
# The pinned upstream checkout stays clean; an upstream update must recheck it.
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/.deps/ui2"
revision="$(tr -d '[:space:]' < "$root/desktop/ui2.commit")"
: "${1:?Usage: prepare-ui2.sh NEW_MODULE_DIRECTORY/ui2}"
destination="$1"
if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$root/.deps"
  git clone https://github.com/vlang/ui2.git "$source_dir" >&2
  git -C "$source_dir" checkout --detach "$revision" >&2
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" ||
      -n "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
  echo 'ui2 must be a clean checkout matching desktop/ui2.commit.' >&2
  exit 1
fi
if [[ -e "$destination" ]]; then
  echo 'ui2 staging destination must not already exist.' >&2
  exit 1
fi
mkdir -p "$(dirname "$destination")"
git clone --quiet --shared --no-checkout --config core.autocrlf=false "$source_dir" "$destination"
git -C "$destination" checkout --quiet --detach "$revision"
for patch_file in "$root/desktop/patches/ui2-native-pointer-uint.patch" \
                  "$root/desktop/patches/ui2-custom-text-shortcuts.patch" \
                  "$root/desktop/patches/ui2-windows-workbench-rendering.patch" \
                  "$root/desktop/patches/ui2-windows-focus-borders.patch"; do
  git -C "$destination" apply --check "$patch_file"
  git -C "$destination" apply "$patch_file"
done
printf '%s\n' "$destination"
