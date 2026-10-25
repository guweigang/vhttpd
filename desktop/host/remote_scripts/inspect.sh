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
if [ -x "$root/runtime/vhttpd" ]; then
  version=$("$root/runtime/vhttpd" --version 2>/dev/null) || {
    echo 'VHTTPD_ERROR:已安装运行包无法执行，请检查架构、系统版本及动态库。'; exit 1;
  }
  printf 'VHTTPD_VERSION:%s\n' "$version"
fi
