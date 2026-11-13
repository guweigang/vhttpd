set -eu
os=$(uname -s)
arch=$(uname -m)
case "$os:$arch" in
  Linux:x86_64) platform=linux-amd64 ;;
  Linux:aarch64|Linux:arm64) platform=linux-arm64 ;;
  *) echo 'VHTTPD_ERROR:当前仅支持 Linux amd64 / arm64 服务器。'; exit 1 ;;
esac
root="$HOME/.local/share/vhttpd-workbench"
printf 'VHTTPD_PLATFORM:%s\n' "$platform"
printf 'VHTTPD_ROOT:%s\n' "$(printf %s "$root" | base64 | tr -d '\n')"
# Legacy storage remains in place: running binaries and their restart paths stay valid.
report_runtime() {
  id="$1"
  dir="$2"
  [ ! -L "$dir" ] && [ -x "$dir/vhttpd" ] && [ -f "$dir/admin/ui/index.html" ] || return 0
  version=$("$dir/vhttpd" --version 2>/dev/null) || {
    echo 'VHTTPD_ERROR:已安装运行包无法执行，请检查架构、系统版本及动态库。'; exit 1;
  }
  tag=''
  if [ -f "$dir/.release-tag" ]; then tag=$(head -c 128 "$dir/.release-tag"); fi
  printf 'VHTTPD_RUNTIME:%s:%s:%s\n' "$id" "$(printf %s "$version" | base64 | tr -d '\n')" "$(printf %s "$tag" | base64 | tr -d '\n')"
}
report_runtime legacy "$root/runtime"
count=0
for dir in "$root/runtimes"/sha256-*; do
  [ -d "$dir" ] || continue
  count=$((count + 1))
  [ "$count" -le 64 ] || { echo 'VHTTPD_ERROR:运行包超过 64 个，请整理后刷新。'; exit 1; }
  report_runtime "${dir##*/}" "$dir"
done
