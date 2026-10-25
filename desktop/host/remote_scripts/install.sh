root="$HOME/.local/share/vhttpd-workbench"
archive="$HOME/$upload"
stage="$root/.install-$upload"
trap 'rm -f "$archive"; rm -rf "$stage"' EXIT HUP INT TERM
[ ! -e "$root/runtime" ] || { echo 'VHTTPD_ERROR:运行包已存在，第一版不执行覆盖升级。'; exit 1; }
printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null || {
  echo 'VHTTPD_ERROR:上传后的 SHA256 校验失败，未安装。'; exit 1;
}
mkdir -p "$root"
chmod 700 "$root"
mkdir -m 700 "$stage"
tar -xzf "$archive" -C "$stage" --no-same-owner --no-same-permissions
package="$stage/vhttpd-$platform"
[ -x "$package/vhttpd" ] && [ -f "$package/admin/ui/index.html" ] || {
  echo 'VHTTPD_ERROR:运行包不完整，请使用官方 CI 完整包。'; exit 1;
}
"$package/vhttpd" --version >/dev/null 2>&1 || {
  echo 'VHTTPD_ERROR:运行包无法执行；请检查 CPU 架构、glibc 版本及动态库兼容性。'; exit 1;
}
# A lock makes the final rename exclusive across Desktop sessions.
mkdir "$root/.install-lock" || { echo 'VHTTPD_ERROR:另一安装正在进行，请稍后刷新。'; exit 1; }
trap 'rmdir "$root/.install-lock"; rm -f "$archive"; rm -rf "$stage"' EXIT HUP INT TERM
[ ! -e "$root/runtime" ] || exit 1
mv "$package" "$root/runtime"
