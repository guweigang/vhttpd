set -C
[ ! -L "$project" ] && [ -f "$project/.desktop-instance-id" ] || exit 1
[ ! -L "$dir" ] && [ -f "$dir/plan.json" ] || exit 1
lock="$project/.desktop-runtime-lock"
mkdir "$lock" || { echo 'VHTTPD_ERROR:该实例正在部署、升级或恢复，请稍后重试。'; exit 1; }
launched=0
trap 'if [ "$launched" = 0 ]; then rm -f "$lock/owner"; rmdir "$lock"; fi' EXIT HUP INT TERM
printf %s "$id" > "$lock/owner"
printf %s "$request" | base64 -d > "$dir/request.json"
printf %s "$id" > "$project/.desktop-deploy-current.tmp"
mv "$project/.desktop-deploy-current.tmp" "$project/.desktop-deploy-current"
# Persist a readable initial status before Desktop starts polling.
printf %s "$status" | base64 -d > "$dir/status.json"
nohup "$binary" --workbench-deploy-helper "$dir/request.json" > "$dir/runtime.log" 2>&1 < /dev/null &
launched=1
