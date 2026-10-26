root="$HOME/.local/share/vhttpd-workbench"
archive="$HOME/$upload"
stage="$root/.install-$upload"
trap 'rm -f "$archive"; rm -rf "$stage"' EXIT HUP INT TERM
printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null || {
  echo 'VHTTPD_ERROR:上传后的 SHA256 校验失败，未安装。'; exit 1;
}
mkdir -p "$root/runtimes"
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
if [ -n "$release_tag" ]; then printf %s "$release_tag" > "$package/.release-tag"; fi
printf %s "$expected" > "$package/.package-sha256"
runtime_id="sha256-$expected"
target="$root/runtimes/$runtime_id"
mkdir "$root/.install-lock" || { echo 'VHTTPD_ERROR:另一安装正在进行，请稍后刷新。'; exit 1; }
trap 'rmdir "$root/.install-lock"; rm -f "$archive"; rm -rf "$stage"' EXIT HUP INT TERM
if [ -e "$target" ]; then
  [ ! -L "$target" ] && [ "$(cat "$target/.package-sha256" 2>/dev/null)" = "$expected" ] && [ -x "$target/vhttpd" ] && [ -f "$target/admin/ui/index.html" ] || {
    echo 'VHTTPD_ERROR:同校验值的运行包目录异常，未覆盖任何版本。'; exit 1;
  }
else
  mv "$package" "$target"
fi
