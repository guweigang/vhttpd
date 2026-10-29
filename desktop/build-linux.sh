#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'Run this build on Linux.' >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) echo 'Unsupported architecture' >&2; exit 1 ;; esac
export VJSX_DIR="${VJSX_DIR:-$root/.deps/vjsx}"
bash "$root/scripts/ensure-vjsx.sh" >/dev/null
# Supply a complete, previously verified native service package. Runtime and
# Desktop compilers can be pinned independently; never copy a developer tree.
: "${VHTTPD_LINUX_RUNTIME_PACKAGE:?Set this to an extracted complete vhttpd-linux-$arch directory}"
service="$(cd "$VHTTPD_LINUX_RUNTIME_PACKAGE" && pwd)"
[[ -x "$service/vhttpd" && -f "$service/admin/ui/index.html" && -d "$service/runtime/libs" ]]
python3 "$root/scripts/ci/verify_gc_runtime.py" "$service/vhttpd"
compiler="${VHTTPD_DESKTOP_V:-v}"
version="$(python3 "$root/desktop/workbench_version.py" --field version)"
mkdir -p "$root/desktop/bin"
stage="$(mktemp -d "$root/desktop/bin/.linux-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bash "$root/desktop/prepare-ui2.sh" "$stage/modules/ui2" >/dev/null
name="vhttpd-workbench-linux-$arch-$version"
package="$stage/$name"
mkdir -p "$package/resources" "$package/runtime/admin" "$package/runtime/runtime"
python3 "$root/desktop/package_linux_fonts.py" "$package/fonts"
"$compiler" -prod -nocache -gc boehm -cc gcc -d build_quickjs -d use_bundled_libgc -w -enable-globals \
 -path "$root/desktop|$root/src|$stage/modules|$(dirname "$VJSX_DIR")|$root/.deps|@vlib|@vmodules" -o "$package/vhttpd-workbench" "$root/desktop"
cp "$root/admin/ui/brand/mark.png" "$package/resources/vhttpd-mark.png"
cp "$service/vhttpd" "$package/runtime/vhttpd"
cp -R "$service/admin/ui" "$package/runtime/admin/ui"
cp -R "$service/runtime/libs" "$package/runtime/runtime/libs"
bash "$root/scripts/bundle_runtime_libs.sh" "$package/vhttpd-workbench" "$package/runtime/libs"
python3 -c 'import platform; print("构建基线：" + platform.freedesktop_os_release()["PRETTY_NAME"] + " / " + platform.machine() + " / " + " ".join(platform.libc_ver()))' > "$package/安装说明.txt"
cat >> "$package/安装说明.txt" <<'GUIDE'
vhttpd Workbench Linux 开发预览

解压整个目录后运行 ./vhttpd-workbench。源码与应用数据另存，不要只复制 ELF。
请使用与构建基线兼容的同架构 Linux 桌面，需 X11 / XWayland、OpenGL 和可用显卡驱动。
需系统 OpenSSH/scp、curl、tar、xdg-open；文件选择器使用 zenity 或 kdialog。
剪贴板需 xclip、xsel 或 wl-clipboard；支持 Ctrl+A/C/X/V，密码框只允许粘贴。
已包含中文与符号字体，无需 V、Node、npm、字体安装或 C 编译器。
不同发行版、Wayland 原生和 Windows 尚未完成验收。
SSH 密码只在本次会话使用；首次连接需确认主机指纹。
默认数据目录为 $XDG_DATA_HOME/vhttpd-workbench 或 ~/.local/share/vhttpd-workbench。
GUIDE
archive="$root/desktop/bin/$name.tar.gz"
tar -czf "$stage/$name.tar.gz" -C "$stage" "$name"
sha256sum "$stage/$name.tar.gz" | sed "s|$stage/||" > "$stage/$name.tar.gz.sha256"
mv "$stage/$name.tar.gz" "$archive"
mv "$stage/$name.tar.gz.sha256" "$archive.sha256"
printf '%s\n' "$archive"
