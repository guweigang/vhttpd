#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
source_dir="$root/desktop/ci/repro_macos_menu_escape"
out="$(mktemp -d "${TMPDIR:-/tmp}/vhttpd-menu-escape.XXXXXX")"
bash "$root/desktop/prepare-ui2.sh" "$out/modules/ui2" >/dev/null
mkdir -p "$out/cocoa-menu-control.app/Contents/MacOS" "$out/ui2-menu-probe.app/Contents/MacOS"
clang -mmacosx-version-min=15.0 -framework Cocoa "$source_dir/cocoa_control.m" -o "$out/cocoa-menu-control.app/Contents/MacOS/probe"
V_MACOS_V3_NO_FALLBACK=1 v -new-compiler -gc none -enable-globals -w \
  -path "$out/modules|@vlib|@vmodules" \
  -o "$out/ui2-menu-probe.app/Contents/MacOS/probe" "$source_dir/ui2_probe.v"
python3 - "$out" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
for app, name, identifier in [
    ('cocoa-menu-control', 'Cocoa Menu Control', 'io.vhttpd.cocoa-menu-control'),
    ('ui2-menu-probe', 'ui2 Menu Escape Probe', 'io.vhttpd.ui2-menu-escape-probe'),
]:
    (root / (app + '.app') / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'probe', 'CFBundleIdentifier': identifier,
        'CFBundleName': name, 'CFBundlePackageType': 'APPL',
    }))
    print(root / (app + '.app'))
PY
