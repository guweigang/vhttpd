root="$HOME/.local/share/vhttpd-workbench"
target="$root/instances/$name"
case "$runtime_id" in
  legacy) runtime="$root/runtime" ;;
  sha256-*) runtime="$root/runtimes/$runtime_id" ;;
  *) echo 'VHTTPD_ERROR:请选择已安装的运行包版本。'; exit 1 ;;
esac
[ -x "$runtime/vhttpd" ] && [ -f "$runtime/admin/ui/index.html" ] || { echo 'VHTTPD_ERROR:所选运行包不可用，请刷新运行环境。'; exit 1; }
mkdir -p "$root/instances"
fresh=0
if mkdir -m 700 "$target"; then
fresh=1
printf %s "$instance_id" > "$target/.desktop-instance-id"
printf %s "$config" | base64 -d > "$target/vhttpd.toml"
if [ -n "$source" ]; then
  printf %s "$source" | base64 -d > "$target/main.mjs"
  chmod 600 "$target/main.mjs"
fi
chmod 600 "$target/vhttpd.toml"
mkdir -m 700 "$target/apps" "$target/.runtime"
elif [ "$reuse" != 1 ] || [ ! -f "$target/vhttpd.toml" ] || [ "$(cat "$target/.desktop-instance-id" 2>/dev/null)" != "$instance_id" ]; then
  echo 'VHTTPD_ERROR:实例目录已存在或无法写入，请换一个名称。'; exit 1
fi
mkdir "$target/.desktop-runtime-lock" || { echo 'VHTTPD_ERROR:另一创建操作正在进行，请稍后重试。'; exit 1; }
trap 'rmdir "$target/.desktop-runtime-lock"' EXIT HUP INT TERM
# Bind once. Retrying a failed creation cannot silently select another runtime.
if [ -f "$target/.desktop-runtime-id" ]; then
  [ "$(cat "$target/.desktop-runtime-id")" = "$runtime_id" ] || { echo 'VHTTPD_ERROR:实例已绑定其他运行包，请使用原版本重试。'; exit 1; }
else
  if [ "$fresh" = 0 ] && [ "$runtime_id" != legacy ]; then
    echo 'VHTTPD_ERROR:旧实例保留原运行包，请选择原有版本重试。'; exit 1
  fi
  printf %s "$runtime_id" > "$target/.desktop-runtime-id"
  chmod 600 "$target/.desktop-runtime-id"
fi
# Process startup is centralized in start.sh after discovery, including retry ownership checks.
