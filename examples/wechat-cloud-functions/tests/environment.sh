#!/usr/bin/env bash
# Shared disposable process lifecycle; all JavaScript executes in vjsx.
set -euo pipefail
wcf_example=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
wcf_repository=$(CDPATH= cd -- "$wcf_example/../.." && pwd)
cd "$wcf_repository"
wcf_binary=${VHTTPD_BIN:-"$wcf_repository/vhttpd"}
wcf_vjsx=${VJSX_BIN:-vjsx}
if [[ -z "${VJSX_BIN:-}" ]] && ! command -v vjsx >/dev/null && [[ -x "$wcf_repository/../vjsx/bin/vjsx" ]]; then
  wcf_vjsx="$wcf_repository/../vjsx/bin/vjsx"
fi
command -v "$wcf_vjsx" >/dev/null || { echo 'Set VJSX_BIN to the vjsx CLI executable' >&2; exit 1; }
[[ -x "$wcf_binary" ]] || { echo 'Set VHTTPD_BIN to a DB-enabled executable' >&2; exit 1; }
wcf_port=${WCF_LOCAL_PORT:-19886}
wcf_bootstrap=${VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS:-120000}
[[ "$wcf_port" =~ ^[0-9]+$ && "$wcf_bootstrap" =~ ^[0-9]+$ ]] || { echo 'Invalid port/bootstrap timeout' >&2; exit 1; }
((wcf_port >= 1024 && wcf_port <= 65535 && wcf_bootstrap >= 1 && wcf_bootstrap <= 300000)) || exit 1
if command -v lsof >/dev/null && lsof -nP -iTCP:"$wcf_port" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $wcf_port is already occupied" >&2; exit 1
fi
wcf_program() {
  local configured=$1 program=$2
  if [[ -n "$configured" ]]; then printf '%s\n' "$configured"
  elif command -v "$program" >/dev/null; then command -v "$program"
  elif [[ -x "/Applications/Postgres.app/Contents/Versions/latest/bin/$program" ]]; then
    printf '%s\n' "/Applications/Postgres.app/Contents/Versions/latest/bin/$program"
  else echo "Missing PostgreSQL tool: $program" >&2; return 1; fi
}
wcf_initdb=$(wcf_program "${WCF_INITDB:-}" initdb)
wcf_pgctl=$(wcf_program "${WCF_PG_CTL:-}" pg_ctl)
wcf_psql=$(wcf_program "${WCF_PSQL:-}" psql)
wcf_root=$(mktemp -d /tmp/wcf-vjsx.XXXXXX)
wcf_server_pid=''
wcf_pg_started=0
wcf_stop_server() {
  if [[ -n "$wcf_server_pid" ]]; then
    kill -TERM "$wcf_server_pid" 2>/dev/null || true
    (sleep 8; kill -KILL "$wcf_server_pid" 2>/dev/null || true) &
    local killer=$!
    wait "$wcf_server_pid" 2>/dev/null || true
    kill "$killer" 2>/dev/null || true
    wait "$killer" 2>/dev/null || true
    wcf_server_pid=''
  fi
}
wcf_cleanup() {
  wcf_stop_server
  if ((wcf_pg_started)); then "$wcf_pgctl" -D "$wcf_root/postgres" -m fast -w stop >/dev/null || true; fi
  if [[ "${WCF_KEEP_TEST_FILES:-0}" == 1 ]]; then echo "Test files retained: $wcf_root"
  else rm -rf -- "$wcf_root"; echo 'Stopped; temporary database removed.'; fi
}
trap wcf_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$wcf_initdb" -D "$wcf_root/postgres" -U wcf_local -A trust --encoding=UTF8 --no-locale >"$wcf_root/initdb.log" 2>&1
wcf_db_port=$((49152 + $$ % 15000))
for ((attempt=0; attempt<5; attempt++)); do
  if "$wcf_pgctl" -D "$wcf_root/postgres" -l "$wcf_root/postgres.log" -o "-h 127.0.0.1 -p $wcf_db_port -k $wcf_root" -w start >/dev/null 2>&1; then
    wcf_pg_started=1; break
  fi
  wcf_db_port=$((49152 + (wcf_db_port + 1) % 15000))
done
((wcf_pg_started)) || { cat "$wcf_root/postgres.log" >&2; exit 1; }
export WCF_EXAMPLE_ROOT="$wcf_example" WCF_BASE_URL="http://127.0.0.1:$wcf_port"
export WCF_PSQL="$wcf_psql" WCF_DB_PORT="$wcf_db_port"
export WECHAT_APP_ID=local-demo WECHAT_APP_SECRET=local-only-not-a-secret WECHAT_DB_DRIVER=pgsql
export WECHAT_STORAGE_ROOT="$wcf_root/storage" WECHAT_STORAGE_BASE_URL="$WCF_BASE_URL"
export WECHAT_STORAGE_MAX_FILE_BYTES=262144
export WECHAT_BODY_LIMIT_BYTES=524288
export VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS="$wcf_bootstrap"
export VHTTPD_LOG_LEVEL=${VHTTPD_LOG_LEVEL:-error}
"$wcf_psql" -h 127.0.0.1 -p "$wcf_db_port" -U wcf_local -d postgres -v ON_ERROR_STOP=1 \
  -f "$wcf_example/schema.sql" -f "$wcf_example/schema-cloud-pgsql.sql" >"$wcf_root/schema.log"
wcf_start_server() {
  local entry=$1
  # These paths are inserted into TOML strings, not evaluated as shell code.
  [[ "$wcf_root$wcf_example$entry" != *'"'* && "$wcf_root$wcf_example$entry" != *'\'* ]] || exit 1
  cat >"$wcf_root/vhttpd.toml" <<TOML
version = 2
[server]
pid_file = "$wcf_root/vhttpd.pid"
[observability]
event_log = "$wcf_root/events.ndjson"
[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = $wcf_port
[resources.db.wechat]
kind = "pgsql"
host = "127.0.0.1"
port = $wcf_db_port
username = "wcf_local"
password = ""
database = "postgres"
pool_size = 4
options = {socket = "$wcf_root/db.sock", pool_name = "wechat"}
[engines.wechat]
kind = "vjsx"
entry = "$entry"
module_root = "$wcf_example"
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
  "$wcf_binary" --config "$wcf_root/vhttpd.toml" >"$wcf_root/server.log" 2>&1 &
  wcf_server_pid=$!
}
