set -eu
root="$HOME/.local/share/vhttpd-workbench/instances"
count=0
for target in "$root"/*; do
  [ -d "$target" ] && [ ! -L "$target" ] && [ -f "$target/vhttpd.toml" ] || continue
  count=$((count + 1))
  [ "$count" -le 128 ] || { echo 'VHTTPD_ERROR:远端项目超过 128 个，请缩小管理范围。'; exit 1; }
  marker=''
  if [ -f "$target/.desktop-instance-id" ] && [ ! -L "$target/.desktop-instance-id" ]; then marker=$(head -c 24 "$target/.desktop-instance-id"); fi
  binding=''
  if [ -f "$target/.desktop-runtime-id" ] && [ ! -L "$target/.desktop-runtime-id" ]; then binding=$(head -c 71 "$target/.desktop-runtime-id"); fi
  if [ -z "$binding" ] && [ -x "$HOME/.local/share/vhttpd-workbench/runtime/vhttpd" ]; then binding=legacy; fi
  printf 'VHTTPD_PROJECT:%s:%s:%s\n' "$(printf %s "$target/vhttpd.toml" | base64 | tr -d '\n')" "$marker" "$binding"
  if [ -f "$target/.desktop-upgrade-current" ] && [ ! -L "$target/.desktop-upgrade-current" ]; then
    operation=$(head -c 24 "$target/.desktop-upgrade-current")
    case "$operation" in *[!0-9a-f]*|'') continue ;; esac
    status="$target/.desktop-upgrades/$operation/status.json"
    if [ ! -L "$status" ] && [ -f "$status" ] && [ "$(wc -c < "$status")" -le 16384 ]; then
      printf 'VHTTPD_UPGRADE:%s\n' "$(base64 < "$status" | tr -d '\n')"
    fi
  fi
done
# Discover only this SSH user's running vhttpd processes. Arguments travel over
# SSH and are parsed in memory; they must never be displayed as diagnostics.
uid=$(id -u)
count=0
for process in /proc/[0-9]*; do
  exe=$(readlink "$process/exe" 2>/dev/null) || continue
  case "$exe" in */vhttpd|*/'vhttpd (deleted)') ;; *) continue ;; esac
  [ "$(stat -c %u "$process" 2>/dev/null)" = "$uid" ] || continue
  cwd=$(readlink "$process/cwd" 2>/dev/null) || continue
  [ -r "$process/cmdline" ] || continue
  count=$((count + 1))
  [ "$count" -le 128 ] || { echo 'VHTTPD_ERROR:运行实例过多，请缩小管理范围。'; exit 1; }
  printf 'VHTTPD_RUNNING:%s:%s:%s\n' "$(printf %s "$cwd" | base64 | tr -d '\n')" "$(head -c 16384 "$process/cmdline" | base64 | tr -d '\n')" "$(printf %s "$exe" | base64 | tr -d '\n')"
done
