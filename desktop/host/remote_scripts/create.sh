root="$HOME/.local/share/vhttpd-workbench"
target="$root/instances/$name"
mkdir -p "$root/instances"
if mkdir -m 700 "$target"; then
printf %s "$instance_id" > "$target/.desktop-instance-id"
printf %s "$config" | base64 -d > "$target/vhttpd.toml"
printf %s "$source" | base64 -d > "$target/main.mjs"
chmod 600 "$target/vhttpd.toml" "$target/main.mjs"
elif [ "$reuse" != 1 ] || [ ! -f "$target/vhttpd.toml" ] || [ "$(cat "$target/.desktop-instance-id" 2>/dev/null)" != "$instance_id" ]; then
  echo 'VHTTPD_ERROR:实例目录已存在或无法写入，请换一个名称。'; exit 1
fi
cd "$target"
# Detach from SSH; the runtime owns authenticated manual restart and project validation.
nohup "$root/runtime/vhttpd" --config "$target/vhttpd.toml" --manual-restart > "$target/process.log" 2>&1 < /dev/null &
pid=$!
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then
  echo 'VHTTPD_ERROR:实例启动失败，可能端口占用或配置无法加载。项目已保留，请检查实例 process.log 后重试。'
  exit 1
fi
