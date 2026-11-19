set -C
# The helper lives in the new immutable runtime package and survives this SSH shell.
[ ! -L "$project" ] && [ -f "$project/.desktop-instance-id" ] || { echo 'VHTTPD_ERROR:项目不属于工作台管理范围。'; exit 1; }
lock="$project/.desktop-runtime-lock"
mkdir "$lock" || { echo 'VHTTPD_ERROR:该实例有运行包操作正在进行，请刷新后查看。'; exit 1; }
launched=0
trap 'if [ "$launched" = 0 ]; then rm -f "$lock/owner"; rmdir "$lock"; fi' EXIT HUP INT TERM
printf %s "$id" > "$lock/owner"
mkdir -p "$project/.desktop-upgrades"
[ ! -L "$project/.desktop-upgrades" ] || exit 1
dir="$project/.desktop-upgrades/$id"
mkdir -m 700 "$dir"
printf %s "$request" | base64 -d > "$dir/request.json"
printf %s "$status" | base64 -d > "$dir/status.json"
printf %s "$id" > "$project/.desktop-upgrade-current.tmp"
mv "$project/.desktop-upgrade-current.tmp" "$project/.desktop-upgrade-current"
nohup "$binary" --workbench-upgrade-helper "$dir/request.json" > "$dir/runtime.log" 2>&1 < /dev/null &
launched=1
