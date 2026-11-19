# Only an existing Desktop-managed instance, with its existing runtime binding.
[ -d "$project" ] && [ ! -L "$project" ] && [ -f "$config" ] && [ ! -L "$config" ] || exit 1
[ ! -L "$project/.desktop-instance-id" ] && [ "$(cat "$project/.desktop-instance-id")" = "$instance_id" ] || exit 1
[ ! -L "$project/.desktop-runtime-id" ] && [ "$(cat "$project/.desktop-runtime-id")" = "$runtime_id" ] || exit 1
[ -x "$binary" ] && [ ! -L "$binary" ] || exit 1
lock="$project/.desktop-runtime-lock"
mkdir "$lock" || { echo 'VHTTPD_ERROR:实例有其他运行操作或重启遗留锁，请先检查远端状态。'; exit 1; }
trap 'rmdir "$lock"' EXIT HUP INT TERM
# Do not spawn a second process, even if the Admin endpoint has not warmed up.
for process in /proc/[0-9]*; do
  exe=$(readlink "$process/exe" 2>/dev/null) || continue
  case "$exe" in */vhttpd|*/'vhttpd (deleted)') ;; *) continue ;; esac
  cwd=$(readlink "$process/cwd" 2>/dev/null) || continue
  if [ "$cwd" = "$project" ]; then
    echo 'VHTTPD_START:already_running'
    exit 0
  fi
done
# Validate without logging configuration contents (which contain credentials).
"$binary" --workbench-upgrade-check "$config" > /dev/null 2>&1 || { echo 'VHTTPD_ERROR:实例配置未通过校验，请检查配置和绑定的运行包。'; exit 1; }
if [ -n "$pid_file" ] && { [ -e "$pid_file" ] || [ -L "$pid_file" ]; }; then
  [ -f "$pid_file" ] && [ ! -L "$pid_file" ] && [ "$(stat -c %u "$pid_file")" = "$(id -u)" ] || { echo 'VHTTPD_ERROR:PID 文件不安全，未启动实例。'; exit 1; }
  old_pid=$(cat "$pid_file")
  case "$old_pid" in ''|*[!0-9]*) echo 'VHTTPD_ERROR:PID 文件内容无效，请检查后再启动。'; exit 1 ;; esac
  [ "${#old_pid}" -le 10 ] && [ "$old_pid" -gt 0 ] || exit 1
  if kill -0 "$old_pid" 2>/dev/null || [ -d "/proc/$old_pid" ]; then
    echo 'VHTTPD_ERROR:PID 仍被进程使用，请检查远端进程后再启动。'
    exit 1
  fi
  [ ! -L "$project/.runtime" ] && [ ! -L "$project/.runtime/pid-backups" ] || exit 1
  mkdir -p "$project/.runtime/pid-backups"
  mv "$pid_file" "$project/.runtime/pid-backups/$(date +%s)-$$.pid"
fi
cd "$project"
[ ! -L "$project/process.log" ] || exit 1
nohup "$binary" --config "$config" --manual-restart >> "$project/process.log" 2>&1 < /dev/null &
pid=$!
sleep 2
kill -0 "$pid" 2>/dev/null || { echo 'VHTTPD_ERROR:实例启动失败，请检查实例目录下的 process.log。'; exit 1; }
echo 'VHTTPD_START:started'
