#!/usr/bin/env bash
# An isolated official MySQL 8.0 container; JavaScript runs only in vjsx.
set -euo pipefail
example=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository=$(CDPATH= cd -- "$example/../.." && pwd)
cd "$repository"
binary=${VHTTPD_BIN:-"$repository/vhttpd"}
vjsx=${VJSX_BIN:-"$repository/../vjsx/bin/vjsx"}
[[ -x "$binary" && -x "$vjsx" ]] || { echo 'Set VHTTPD_BIN and VJSX_BIN' >&2; exit 1; }
root=$(mktemp -d /tmp/wcf-mysql.XXXXXX)
container="vhttpd-wcf-mysql-$$"
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    (sleep 8; kill -KILL "$server_pid" 2>/dev/null || true) &
    killer=$!
    wait "$server_pid" 2>/dev/null || true
    kill "$killer" 2>/dev/null || true
  fi
  docker rm -fv "$container" >/dev/null 2>&1 || true
  if [[ "${WCF_KEEP_TEST_FILES:-0}" == 1 ]]; then echo "Test files: $root"; else rm -rf -- "$root"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker run -d --name "$container" -e MYSQL_ROOT_PASSWORD=fixture-only \
  -e MYSQL_DATABASE=wcf_test -e MYSQL_USER=wcf_local -e MYSQL_PASSWORD=fixture-only \
  -p 127.0.0.1::3306 mysql:8.0 --max-allowed-packet=16777216 >"$root/container.id"
ready=0
for ((attempt=0; attempt<60; attempt++)); do
  # The image first starts a socket-only initialization server, then restarts.
  # Require TCP so schema setup cannot race that temporary server's shutdown.
  if docker exec -e MYSQL_PWD=fixture-only "$container" mysql --protocol=TCP -h 127.0.0.1 -u wcf_local -D wcf_test -N -e 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
((ready)) || { docker logs "$container" >&2; exit 1; }
for schema in schema-auth-mysql.sql schema-cloud-mysql.sql; do
  docker exec -i -e MYSQL_PWD=fixture-only "$container" mysql -u wcf_local -D wcf_test <"$example/$schema"
done
db_port=$(docker port "$container" 3306/tcp | cut -d: -f2)
port=${WCF_LOCAL_PORT:-19891}
[[ "$port" =~ ^[0-9]+$ ]] && ((port>=1024 && port<=65535)) || exit 1
cat >"$root/vhttpd.toml" <<TOML
version = 2
[server]
pid_file = "$root/server.pid"
[observability]
event_log = "$root/events.ndjson"
[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = $port
[resources.db.wechat]
kind = "mysql"
host = "127.0.0.1"
port = $db_port
username = "wcf_local"
password = "fixture-only"
database = "wcf_test"
pool_size = 4
init_sql = ["SET NAMES utf8mb4", "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ"]
options = {socket = "$root/db.sock", pool_name = "wechat"}
[engines.wechat]
kind = "vjsx"
entry = "$example/tests/cloud-entry.mts"
module_root = "$example"
runtime_profile = "node"
thread_count = 2
enable_network = true
resources = ["resource:db/wechat"]
[adapters.wechat]
kind = "http-handler"
engine = "engine:wechat"
[[pipelines]]
id = "wechat"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:wechat"
TOML
export WECHAT_APP_ID=local-demo WECHAT_APP_SECRET=local-only-not-a-secret WECHAT_DB_DRIVER=mysql
export WCF_EXAMPLE_ROOT="$example" WCF_BASE_URL="http://127.0.0.1:$port" WCF_MYSQL_CONTAINER="$container"
export WECHAT_STORAGE_ROOT="$root/storage" WECHAT_STORAGE_BASE_URL="$WCF_BASE_URL"
export WECHAT_STORAGE_MAX_FILE_BYTES=262144 WECHAT_BODY_LIMIT_BYTES=524288
export VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS=120000 VHTTPD_LOG_LEVEL=error
"$binary" --config "$root/vhttpd.toml" >"$root/server.log" 2>&1 &
server_pid=$!
if ! "$vjsx" "$example/tests/mysql-e2e.mjs"; then tail -60 "$root/server.log" >&2; exit 1; fi
