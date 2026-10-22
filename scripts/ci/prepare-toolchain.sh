#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/ci/toolchain.env
source "$root/scripts/ci/toolchain.env"
: "${RUNNER_TEMP:?}"
: "${GITHUB_PATH:?}"
: "${GITHUB_ENV:?}"
toolchain="$RUNNER_TEMP/vhttpd-ci-toolchain"
# A fresh directory prevents preinstalled modules or stale QuickJS from winning.
mkdir "$toolchain"
checkout_pinned() {
  local repository="$1" revision="$2" destination="$3"
  git init -q "$destination"
  git -C "$destination" remote add origin "$repository"
  git -C "$destination" fetch --depth 1 origin "$revision"
  git -C "$destination" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]]
}
checkout_pinned "$V_REPO" "$V_COMMIT" "$toolchain/v"
checkout_pinned "$VJSX_REPO" "$VJSX_COMMIT" "$toolchain/vjsx"
for dependency in v vjsx; do
  git -C "$toolchain/$dependency" apply --check "$root/scripts/ci/$dependency-runtime.patch"
  git -C "$toolchain/$dependency" apply "$root/scripts/ci/$dependency-runtime.patch"
done
checkout_pinned "$VC_REPO" "$VC_COMMIT" "$toolchain/v/vc"
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) selected_tcc="$TCC_LINUX_AMD64_COMMIT" ;;
  Darwin:x86_64) selected_tcc="$TCC_MACOS_AMD64_COMMIT" ;;
  Darwin:arm64) selected_tcc="$TCC_MACOS_ARM64_COMMIT" ;;
  *) echo 'No pinned TCC bundle for this platform' >&2; exit 1 ;;
esac
checkout_pinned "$TCC_REPO" "$selected_tcc" "$toolchain/v/thirdparty/tcc"
file "$toolchain/v/thirdparty/tcc/tcc.exe"
checkout_pinned "$QUICKJS_REPO" "$QUICKJS_COMMIT" "$toolchain/quickjs"
make -C "$toolchain/v" local=1 CC=cc
"$toolchain/v/v" version
mkdir -p "$toolchain/modules"
ln -s "$toolchain/vjsx" "$toolchain/modules/vjsx"
echo "$toolchain/v" >> "$GITHUB_PATH"
{
  echo "VMODULES=$toolchain/modules"
  echo "VJSX_DIR=$toolchain/vjsx"
  echo "VJS_QUICKJS_PATH=$toolchain/quickjs"
} >> "$GITHUB_ENV"
mkdir -p "$root/ci-results"
{
  cat "$root/scripts/ci/toolchain.env"
  echo "TCC_SELECTED_COMMIT=$selected_tcc"
  git -C "$root" rev-parse HEAD
  shasum -a 256 "$root"/scripts/ci/*-runtime.patch
  "$toolchain/v/v" version
  cc --version
  php --version
  node --version
  python3 --version
  composer --version
  pkg-config --modversion bdw-gc openssl sqlite3
} > "$root/ci-results/toolchain.txt"
# OS image packages are resolved by apt/Homebrew; retain their exact installed
# versions instead of claiming those system libraries are hermetically pinned.
if [[ "$(uname -s)" == Darwin ]]; then
  brew list --versions > "$root/ci-results/native-packages.txt"
else
  dpkg-query -W > "$root/ci-results/native-packages.txt"
fi

python3 - "$root" <<'PY_IDENTITY'
import json, os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
def revision(ref):
    return subprocess.check_output(['git', '-C', str(root), 'rev-parse', ref], text=True).strip()
identity = {'source_commit': revision('HEAD'), 'source_tree': revision('HEAD^{tree}')}
for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_EVENT_NAME',
            'GITHUB_SHA', 'GITHUB_WORKFLOW_REF', 'RUNNER_OS', 'RUNNER_ARCH',
            'ImageOS', 'ImageVersion'):
    identity[key] = os.environ.get(key)
(root / 'ci-results' / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
PY_IDENTITY
