#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This desktop prototype currently targets macOS only.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(python3 "$root/desktop/workbench_version.py" --field version)"
bundle_version="$(python3 "$root/desktop/workbench_version.py" --field bundle_version)"
archive_name="vhttpd-workbench-macos-arm64-$version.zip"
ui2_root="$root/.deps/ui2"
revision="$(cat "$root/desktop/ui2.commit")"
if [[ ! -d "$ui2_root/.git" ]]; then
  mkdir -p "$root/.deps"
  git clone https://github.com/vlang/ui2.git "$ui2_root"
  git -C "$ui2_root" checkout --detach "$revision"
fi
if [[ "$(git -C "$ui2_root" rev-parse HEAD)" != "$revision" ]]; then
  echo 'ui2 checkout differs from desktop/ui2.commit; refusing to change an existing checkout.' >&2
  exit 1
fi
if [[ -n "$(git -C "$ui2_root" status --porcelain --untracked-files=no)" ]]; then
  echo 'ui2 has local source changes; refusing an unreproducible prototype build.' >&2
  exit 1
fi
target_app="$root/desktop/bin/vhttpd-workbench.app"
mkdir -p "$root/desktop/bin"
build_dir="$(mktemp -d "$root/desktop/bin/.build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 "$root/desktop/macos_dependencies.py"
export MACOSX_DEPLOYMENT_TARGET=15.0
export VHTTPD_MACOS_DEPS="$root/.deps/macos-sequoia"
export PKG_CONFIG_LIBDIR="$VHTTPD_MACOS_DEPS/opt/mysql-client/lib/pkgconfig:$VHTTPD_MACOS_DEPS/opt/libpq/lib/pkgconfig:$VHTTPD_MACOS_DEPS/opt/openssl@4/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
cat > "$build_dir/clang-compatible" <<EOF
#!/bin/sh
exec python3 "$root/desktop/macos_dependencies.py" --cc "\$@"
EOF
chmod +x "$build_dir/clang-compatible"
# A debug V executable may reload $embed_file from the developer checkout.
# Build both deliverable executables with -prod, using isolated staging paths.
if [[ -n "${VHTTPD_PACKAGE_RUNTIME:-}" ]]; then
  if [[ ! -x "$VHTTPD_PACKAGE_RUNTIME" ]]; then
    echo '指定的交付运行程序不可执行。' >&2
    exit 1
  fi
else
  make -C "$root" prod BUILD_STAGE_ROOT="$build_dir/runtime-src" \
    BUILD_STAGE_DIR="$build_dir/runtime-src" VHTTPD_BIN="$build_dir/vhttpd" \
    V_CC="$build_dir/clang-compatible" VPHP_V_GC=boehm \
    V_FLAGS="-w -d use_openssl -d use_bundled_libgc -enable-globals"
  export VHTTPD_PACKAGE_RUNTIME="$build_dir/vhttpd"
fi
app="$build_dir/vhttpd-workbench.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/desktop/assets/vhttpd-macos.icns" "$app/Contents/Resources/vhttpd-macos.icns"
cp "$root/admin/ui/brand/mark.png" "$app/Contents/Resources/vhttpd-mark.png"
v -prod -nocache -cc "$build_dir/clang-compatible" -d use_bundled_libgc -w -enable-globals -path "$root/desktop|$root/src|$root/.deps|@vlib|@vmodules" \
  -o "$build_dir/vhttpd-workbench" "$root/desktop"
# Replace the directory entry atomically; never truncate the executable that
# a running workbench has mapped into memory.
mv -f "$build_dir/vhttpd-workbench" "$app/Contents/MacOS/vhttpd-workbench"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>vhttpd-workbench</string>
<key>CFBundleIdentifier</key><string>io.vhttpd.workbench.prototype</string>
<key>CFBundleName</key><string>vhttpd Workbench</string>
<key>CFBundleIconFile</key><string>vhttpd-macos.icns</string>
<key>CFBundleShortVersionString</key><string>$bundle_version</string>
<key>CFBundleVersion</key><string>$bundle_version</string>
<key>VHTTPDReleaseVersion</key><string>$version</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 "$root/desktop/package_macos.py" "$root" "$app"
archive="$build_dir/$archive_name"
python3 "$root/desktop/package_macos.py" --archive "$app" "$archive"
# Validate the archive before replacing the previous deliverables.
python3 "$root/desktop/verify_macos_release.py" "$archive"
# Never overwrite a running executable in place. Retain the previous bundle
# until the complete replacement is assembled and signed.
if [[ -d "$target_app" ]]; then mv "$target_app" "$build_dir/previous.app"; fi
if ! mv "$app" "$target_app"; then
  if [[ -d "$build_dir/previous.app" ]]; then mv "$build_dir/previous.app" "$target_app"; fi
  exit 1
fi
mv -f "$archive" "$root/desktop/bin/$archive_name"
echo "$target_app"
