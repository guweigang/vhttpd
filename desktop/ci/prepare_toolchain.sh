#!/bin/bash
set -euo pipefail
# The V bootstrap filters generated C containing arbitrary byte strings with
# awk. A UTF-8 runner locale can truncate that stream before compilation.
export LC_ALL=C
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=desktop/ci/toolchain.env
source "$root/desktop/ci/toolchain.env"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
toolchain="$RUNNER_TEMP/vhttpd-workbench-toolchain"
mkdir -p "$toolchain"
checkout_pinned() {
  local repository="$1" revision="$2" destination="$3"
  git init "$destination"
  git -C "$destination" remote add origin "$repository"
  git -C "$destination" fetch --depth 1 origin "$revision"
  git -C "$destination" checkout --detach FETCH_HEAD
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]]
}
checkout_pinned "$V_REPO" "$V_COMMIT" "$toolchain/v"
checkout_pinned "$VJSX_REPO" "$VJSX_COMMIT" "$toolchain/vjsx"
# These changes are included in the pinned upstream commits; do not reapply
# historical workspace patches to a newer dependency.
checkout_pinned "$VC_REPO" "$VC_COMMIT" "$toolchain/v/vc"
checkout_pinned "$TCC_REPO" "$TCC_COMMIT" "$toolchain/v/thirdparty/tcc"
make -C "$toolchain/v" local=1 CC=cc
"$toolchain/v/v" version
mkdir -p "$toolchain/modules"
ln -s "$toolchain/vjsx" "$toolchain/modules/vjsx"
quickjs="$(VJS_QUICKJS_WORK_ROOT="$root" "$toolchain/vjsx/scripts/ensure-quickjs.sh")"
echo "$toolchain/v" >> "$GITHUB_PATH"
{
  echo "VJSX_DIR=$toolchain/vjsx"
  echo "VMODULES=$toolchain/modules"
  echo "VJS_QUICKJS_PATH=$quickjs"
} >> "$GITHUB_ENV"
