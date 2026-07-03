#!/usr/bin/env bash
# Product-level config acceptance smoke tests for v1/v2 runtime scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VHTTPD_BIN="${REPO_ROOT}/vhttpd"
TMP_ROOT="${TMPDIR:-/tmp}/vhttpd-config-acceptance-$$"
PASS=0
FAIL=0
PIDS=()
LOG_FILES=()

ok()  { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
ko()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        if kill -0 "$pid" >/dev/null 2>&1; then
            kill "$pid" >/dev/null 2>&1 || true
            wait "$pid" >/dev/null 2>&1 || true
        fi
    done
    rm -f /tmp/vhq-"$$"-*
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

require_binary() {
    if [[ ! -x "$VHTTPD_BIN" ]]; then
        echo "ERROR: binary not found: $VHTTPD_BIN"
        echo "Run 'make build' first."
        exit 1
    fi
}

free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

start_vhttpd() {
    local name="$1"
    shift
    local log_file="${TMP_ROOT}/${name}.log"
    "$VHTTPD_BIN" "$@" >"$log_file" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    LOG_FILES+=("$log_file")
    echo "$pid"
}

expect_vhttpd_config_failure() {
    local name="$1"
    local config="$2"
    local needle="$3"
    local label="$4"
    local log_file="${TMP_ROOT}/${name}.log"
    LOG_FILES+=("$log_file")
    set +e
    "$VHTTPD_BIN" --config "$config" >"$log_file" 2>&1
    local status=$?
    set -e
    if [[ "$status" -ne 0 ]] && grep -q "$needle" "$log_file"; then
        ok "$label"
        return 0
    fi
    ko "$label"
    echo "    config: $config"
    echo "    exit: $status"
    echo "    expected: $needle"
    echo "    last log:"
    tail -80 "$log_file" | sed 's/^/      /'
    return 1
}

wait_http_contains() {
    local url="$1"
    local needle="$2"
    local label="$3"
    local body_file="${TMP_ROOT}/body.$RANDOM"
    for _ in $(seq 1 80); do
        if curl -fsS --max-time 2 "$url" >"$body_file" 2>/dev/null; then
            if grep -q "$needle" "$body_file"; then
                ok "$label"
                return 0
            fi
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    url: $url"
    echo "    expected: $needle"
    echo "    last body:"
    sed 's/^/      /' "$body_file" 2>/dev/null || true
    print_logs
    return 1
}

wait_http_header_contains() {
    local url="$1"
    local header="$2"
    local needle="$3"
    local label="$4"
    local header_file="${TMP_ROOT}/headers.$RANDOM"
    local lower_header
    lower_header="$(printf '%s' "$header" | tr '[:upper:]' '[:lower:]')"
    for _ in $(seq 1 80); do
        if curl -sS -D "$header_file" -o /dev/null --max-time 2 "$url" 2>/dev/null; then
            if awk -v h="$lower_header" -v n="$needle" '
                BEGIN { found = 0 }
                {
                    line = $0
                    sub(/\r$/, "", line)
                    lower = tolower(line)
                    if (index(lower, h ":") == 1 && index(line, n) > 0) {
                        found = 1
                    }
                }
                END { exit(found ? 0 : 1) }
            ' "$header_file"; then
                ok "$label"
                return 0
            fi
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    url: $url"
    echo "    header: $header"
    echo "    expected: $needle"
    echo "    last headers:"
    sed 's/^/      /' "$header_file" 2>/dev/null || true
    print_logs
    return 1
}

wait_http_header_contains_with_cookie() {
    local url="$1"
    local cookie="$2"
    local header="$3"
    local needle="$4"
    local label="$5"
    local header_file="${TMP_ROOT}/headers.$RANDOM"
    local lower_header
    lower_header="$(printf '%s' "$header" | tr '[:upper:]' '[:lower:]')"
    for _ in $(seq 1 80); do
        if curl -sS -H "Cookie: ${cookie}" -D "$header_file" -o /dev/null --max-time 2 "$url" 2>/dev/null; then
            if awk -v h="$lower_header" -v n="$needle" '
                BEGIN { found = 0 }
                {
                    line = $0
                    sub(/\r$/, "", line)
                    lower = tolower(line)
                    if (index(lower, h ":") == 1 && index(line, n) > 0) {
                        found = 1
                    }
                }
                END { exit(found ? 0 : 1) }
            ' "$header_file"; then
                ok "$label"
                return 0
            fi
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    url: $url"
    echo "    cookie: $cookie"
    echo "    header: $header"
    echo "    expected: $needle"
    echo "    last headers:"
    sed 's/^/      /' "$header_file" 2>/dev/null || true
    print_logs
    return 1
}

wait_http_status_contains() {
    local url="$1"
    local expected_status="$2"
    local needle="$3"
    local label="$4"
    local body_file="${TMP_ROOT}/body.$RANDOM"
    local status
    for _ in $(seq 1 80); do
        status="$(curl -sS --max-time 2 -o "$body_file" -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [[ "$status" == "$expected_status" ]] && { [[ -z "$needle" ]] || grep -q "$needle" "$body_file" 2>/dev/null; }; then
            ok "$label"
            return 0
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    url: $url"
    echo "    expected status: $expected_status"
    [[ -n "$needle" ]] && echo "    expected body: $needle"
    echo "    last status: ${status:-}"
    echo "    last body:"
    sed 's/^/      /' "$body_file" 2>/dev/null || true
    print_logs
    return 1
}

expect_http_status_contains_once() {
    local url="$1"
    local expected_status="$2"
    local needle="$3"
    local label="$4"
    local max_time="${5:-3}"
    local body_file="${TMP_ROOT}/body.$RANDOM"
    local status
    status="$(curl -sS --max-time "$max_time" -o "$body_file" -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$status" == "$expected_status" ]] && { [[ -z "$needle" ]] || grep -q "$needle" "$body_file" 2>/dev/null; }; then
        ok "$label"
        return 0
    fi
    ko "$label"
    echo "    url: $url"
    echo "    expected status: $expected_status"
    [[ -n "$needle" ]] && echo "    expected body: $needle"
    echo "    actual status: ${status:-}"
    echo "    body:"
    sed 's/^/      /' "$body_file" 2>/dev/null || true
    print_logs
    return 1
}

wait_http_post_contains() {
    local url="$1"
    local data="$2"
    local needle="$3"
    local label="$4"
    local body_file="${TMP_ROOT}/body.$RANDOM"
    for _ in $(seq 1 80); do
        if curl -fsS --max-time 2 -H 'content-type: application/json' \
            --data "$data" "$url" >"$body_file" 2>/dev/null; then
            if grep -q "$needle" "$body_file"; then
                ok "$label"
                return 0
            fi
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    url: $url"
    echo "    expected: $needle"
    echo "    last body:"
    sed 's/^/      /' "$body_file" 2>/dev/null || true
    print_logs
    return 1
}

wait_http_post_status_contains() {
    local url="$1"
    local data="$2"
    local expected_status="$3"
    local needle="$4"
    local label="$5"
    local body_file="${TMP_ROOT}/body.$RANDOM"
    local status
    for _ in $(seq 1 80); do
        status="$(curl -sS --max-time 2 -H 'content-type: application/json' \
            --data "$data" -o "$body_file" -w '%{http_code}' "$url" 2>/dev/null || true)"
        if [[ "$status" == "$expected_status" ]] && { [[ -z "$needle" ]] || grep -q "$needle" "$body_file" 2>/dev/null; }; then
            ok "$label"
            return 0
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    url: $url"
    echo "    expected status: $expected_status"
    [[ -n "$needle" ]] && echo "    expected body: $needle"
    echo "    last status: ${status:-}"
    echo "    last body:"
    sed 's/^/      /' "$body_file" 2>/dev/null || true
    print_logs
    return 1
}

wait_http_text_post_contains() {
    local url="$1"
    local data="$2"
    local needle="$3"
    local label="$4"
    local body_file="${TMP_ROOT}/body.$RANDOM"
    for _ in $(seq 1 80); do
        if curl -fsS --max-time 2 -H 'content-type: text/plain' \
            --data-binary "$data" "$url" >"$body_file" 2>/dev/null; then
            if grep -q "$needle" "$body_file"; then
                ok "$label"
                return 0
            fi
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    url: $url"
    echo "    expected: $needle"
    echo "    last body:"
    sed 's/^/      /' "$body_file" 2>/dev/null || true
    print_logs
    return 1
}

wait_event_contains() {
    local file="$1"
    local needle="$2"
    local label="$3"
    for _ in $(seq 1 80); do
        if [[ -f "$file" ]] && grep -q "$needle" "$file"; then
            ok "$label"
            return 0
        fi
        sleep 0.25
    done
    ko "$label"
    echo "    file: $file"
    echo "    expected: $needle"
    [[ -f "$file" ]] && tail -20 "$file" | sed 's/^/      /'
    print_logs
    return 1
}

print_logs() {
    for log_file in "${LOG_FILES[@]:-}"; do
        [[ -f "$log_file" ]] || continue
        echo "    log: $log_file"
        tail -80 "$log_file" | sed 's/^/      /'
    done
}

write_v1_hello_config() {
    local file="$1"
    local port="$2"
    cat >"$file" <<EOF
[server]
host = "127.0.0.1"
port = ${port}

[files]
pid_file = "${TMP_ROOT}/v1.pid"
event_log = "${TMP_ROOT}/v1.events.ndjson"

[executor]
kind = "vjsx"

[vjsx]
app_entry = "${REPO_ROOT}/examples/vjsx/hello-handler.mts"
runtime_profile = "node"
thread_count = 1

[admin]
host = "127.0.0.1"
port = 0
token = ""
EOF
}

write_v2_hello_config() {
    local file="$1"
    local port="$2"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/v2.pid"

[observability]
event_log = "${TMP_ROOT}/v2.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[engines.hello]
kind = "vjsx"
entry = "${REPO_ROOT}/examples/vjsx/hello-handler.mts"
runtime_profile = "node"
thread_count = 1

[adapters.hello]
kind = "http-handler"
engine = "engine:hello"

[[pipelines]]
id = "hello"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:hello"
EOF
}

write_v2_missing_reference_config() {
    local file="$1"
    local port="$2"
    local case_name="$3"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/missing-${case_name}.pid"

[observability]
event_log = "${TMP_ROOT}/missing-${case_name}.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[engines.hello]
kind = "vjsx"
entry = "${REPO_ROOT}/examples/vjsx/hello-handler.mts"
runtime_profile = "node"
thread_count = 1

[adapters.hello]
kind = "http-handler"
engine = "engine:hello"

[transforms.noop]
kind = "native"
handler = "noop"

[[pipelines]]
id = "hello"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:hello"
EOF

    case "$case_name" in
        adapter)
            cat >>"$file" <<'EOF'

[[pipelines]]
id = "missing-adapter"
ingress = "listener:web"
match.paths = ["/missing-adapter"]
egress = "adapter:missing-adapter"
EOF
            ;;
        transform)
            cat >>"$file" <<'EOF'

[[pipelines]]
id = "missing-transform"
ingress = "listener:web"
match.paths = ["/missing-transform"]
transforms = ["transform:missing-transform"]
egress = "adapter:hello"
EOF
            ;;
        listener)
            cat >>"$file" <<'EOF'

[[pipelines]]
id = "missing-listener"
ingress = "listener:missing-listener"
match.paths = ["/missing-listener"]
egress = "adapter:hello"
EOF
            ;;
        resource)
            cat >>"$file" <<'EOF'

[engines.needs-resource]
kind = "vjsx"
entry = "examples/vjsx/hello-handler.mts"
resources = ["resource:missing-resource"]

[adapters.needs-resource]
kind = "http-handler"
engine = "engine:needs-resource"

[[pipelines]]
id = "missing-resource"
ingress = "listener:web"
match.paths = ["/missing-resource"]
egress = "adapter:needs-resource"
EOF
            ;;
        *)
            echo "unknown missing-reference case: $case_name" >&2
            return 1
            ;;
    esac
}

write_relay_public_config() {
    local file="$1"
    local http_port="$2"
    local ws_port="$3"
    local relay_path="${4:-/vhttpd/relay}"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/relay-public.pid"

[observability]
event_log = "${TMP_ROOT}/relay-public.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${http_port}

[listeners.relay]
protocol = "websocket"
transport = "tcp"
host = "127.0.0.1"
port = ${ws_port}

[relays.edge]
mode = "hub"
carrier = "websocket"
listener = "listener:relay"
path = "${relay_path}"
node_id = "hub-local"
token = "change-me"
max_channels = 1024
channel_buffer = 64

[adapters.relay-edge]
kind = "relay-delivery"
options.target = "relay:edge"
options.completion_mode = "wait"
int_options.completion_timeout_ms = 30000
options.frame_kind = "open"
options.route = "relay/local-response"

[[pipelines]]
id = "public/relay"
ingress = "listener:web"
match.paths = ["/relay"]
egress = "adapter:relay-edge"
EOF
}

write_relay_agent_config() {
    local file="$1"
    local port="$2"
    local ws_port="$3"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/relay-agent.pid"

[observability]
event_log = "${TMP_ROOT}/relay-agent.events.ndjson"

[listeners.local]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[relays.edge]
mode = "agent"
carrier = "websocket"
url = "ws://127.0.0.1:${ws_port}/vhttpd/relay"
node_id = "agent-local"
token = "change-me"
autostart = true
reconnect_delay_ms = 1000
channel_buffer = 64

[adapters.local-response]
kind = "fixed-response"
options.status = "200"
options.body = "relay agent ok"

[adapters.health]
kind = "fixed-response"
options.status = "200"
options.body = "relay agent health ok"

[[pipelines]]
id = "local/health"
ingress = "listener:local"
match.paths = ["/health"]
egress = "adapter:health"

[[pipelines]]
id = "relay/local-response"
ingress = "relay:edge"
egress = "adapter:local-response"
EOF
}

write_multisite_config() {
    local file="$1"
    local blog_port="$2"
    local shop_port="$3"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/multisite.pid"

[observability]
event_log = "${TMP_ROOT}/multisite.events.ndjson"

[listeners.blog]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${blog_port}

[listeners.shop]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${shop_port}

[adapters.blog-home]
kind = "fixed-response"
options.status = "200"
options.body = "blog site ok"

[adapters.shop-home]
kind = "fixed-response"
options.status = "200"
options.body = "shop site ok"

[[pipelines]]
id = "blog/home"
group = "site:blog"
ingress = "listener:blog"
match.paths = ["*"]
egress = "adapter:blog-home"

[[pipelines]]
id = "shop/home"
group = "site:shop"
ingress = "listener:shop"
match.paths = ["*"]
egress = "adapter:shop-home"
EOF
}

write_wordpress_v2_smoke_config() {
    local file="$1"
    local port="$2"
    local wp_root="$3"
    local label="${4:-wordpress-v2}"
    local include_db="${5:-0}"
    local short_socket_prefix="/tmp/vhq-$$-${label}"
    local db_resource_block=""
    local php_resources='"resource:storage/wordpress", "resource:cache/wordpress"'
    local db_env_block=""
    if [[ "$include_db" == "1" ]]; then
        local db_host="${VHTTPD_E2E_DB_HOST:-127.0.0.1}"
        local db_port="${VHTTPD_E2E_DB_PORT:-3306}"
        local db_user="${VHTTPD_E2E_DB_USER:-root}"
        local db_password="${VHTTPD_E2E_DB_PASSWORD:-}"
        local db_name="${VHTTPD_E2E_WP_DB_NAME:-${VHTTPD_E2E_DB_NAME:-wordpress}}"
        db_resource_block="[resources.db.wordpress]
kind = \"mysql\"
host = \"${db_host}\"
port = ${db_port}
username = \"${db_user}\"
password = \"${db_password}\"
database = \"${db_name}\"
pool_size = 2
idle_ping_ms = 30000
init_sql = [\"SET NAMES utf8mb4\", \"SET SESSION sql_mode = ''\"]
options = { socket = \"${short_socket_prefix}-db.sock\", pool_name = \"wordpress\" }"
        php_resources='"resource:db/wordpress", '"${php_resources}"
        db_env_block="VHTTPD_DB_SOCKET = \"${short_socket_prefix}-db.sock\"
VHTTPD_DB_POOL = \"wordpress\"
VHTTPD_DB_TIMEOUT_MS = \"3000\""
    fi
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/${label}.pid"

[observability]
event_log = "${TMP_ROOT}/${label}.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[resources.storage.wordpress]
kind = "filesystem"
root = "${wp_root}"

${db_resource_block}

[resources.cache.wordpress]
kind = "session-store"
socket = "${short_socket_prefix}-cache.sock"
namespace = "${label}"

[engines.php]
kind = "php-worker"
entry = "${REPO_ROOT}/php/package/bin/vphp-worker"
app = "${REPO_ROOT}/examples/wordpress/app.php"
autostart = true
pool_size = 1
socket = "${short_socket_prefix}.sock"
queue_capacity = 8
queue_timeout_ms = 1000
resources = [${php_resources}]

[engines.php.env]
VPHP_WP_ROOT = "${wp_root}"
VHTTPD_VENDOR = "${REPO_ROOT}/php/package"
${db_env_block}
VHTTPD_SCHEME = "http"
VHTTPD_REQUEST_SCHEME = "http"

[adapters.wordpress-worker]
kind = "http-handler"
engine = "engine:php"
storage = "resource:storage/wordpress"
document_root = "${wp_root}"
index = "index.php"

[adapters.wordpress-static]
kind = "static"
storage = "resource:storage/wordpress"
root = "${wp_root}"

[adapters.forbidden]
kind = "fixed-response"
options.status = "403"
options.body = "Forbidden"

[policies.cache.asset-short]
cache_control = "public, max-age=3600"

[policies.cache.front-page]
cache_control = "public, max-age=30"
ttl_ms = 30000
bypass_cookie_patterns = ["wordpress_logged_in_*", "wordpress_sec_*", "wp-postpass_*", "comment_author_*", "woocommerce_items_in_cart", "woocommerce_cart_hash", "wp_woocommerce_session_*"]
ignore_cookie_patterns = ["wordpress_test_cookie", "wp-settings-*", "wp-settings-time-*"]

[[pipelines]]
id = "assets.by-extension"
group = "wordpress.assets"
ingress = "listener:web"
match.paths = ["*.css", "*.js", "*.png", "*.jpg", "*.jpeg", "*.gif", "*.svg", "*.ico", "*.woff", "*.woff2", "*.ttf"]
policies = ["policy:cache/asset-short"]
egress = "adapter:wordpress-static"

[[pipelines]]
id = "assets.wordpress-directories"
group = "wordpress.assets"
ingress = "listener:web"
match.paths = ["/wp-content/*", "/wp-includes/*", "/favicon.ico", "robots.txt"]
policies = ["policy:cache/asset-short"]
egress = "adapter:wordpress-static"

[[pipelines]]
id = "security.deny-core-files"
group = "wordpress.security"
ingress = "listener:web"
match.paths = ["/wp-config.php", "/wp-config-sample.php", "/wp-load.php", "/wp-settings.php", "/wp-blog-header.php"]
egress = "adapter:forbidden"

[[pipelines]]
id = "wordpress.meta"
group = "wordpress.dynamic"
ingress = "listener:web"
match.paths = ["/meta"]
policies = ["policy:cache/front-page"]
egress = "adapter:wordpress-worker"

[[pipelines]]
id = "wordpress.front-page"
group = "wordpress.dynamic"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:wordpress-worker"
EOF
}

write_protocol_transform_handler() {
    local file="$1"
    cat >"$file" <<'EOF'
function handle(ctx) {
  if (ctx.path.includes("transform.throw")) {
    throw new Error("transform exploded");
  }
  if (ctx.path.includes("transform.fail")) {
    return {
      status: 500,
      headers: { "content-type": "text/plain; charset=utf-8" },
      body: "transform failed",
    };
  }
  return ctx.json({
    ok: true,
    path: ctx.path,
    traceId: ctx.runtime.traceId,
  }, 200);
}

globalThis.__vhttpd_handle = handle;
export default handle;
EOF
}

write_protocol_native_config() {
    local file="$1"
    local port="$2"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/protocol-native.pid"

[observability]
event_log = "${TMP_ROOT}/protocol-native.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[transforms.convert]
kind = "native"
handler = "test.noop"

[adapters.convert]
kind = "fixed-response"
options.status = "200"
options.body = "native transform ok"

[[pipelines]]
id = "protocol/native"
ingress = "listener:web"
match.paths = ["/convert"]
transforms = ["transform:convert"]
egress = "adapter:convert"
EOF
}

write_protocol_vjsx_config() {
    local file="$1"
    local port="$2"
    local handler="$3"
    local body="${4:-vjsx transform ok}"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/protocol-vjsx.pid"

[observability]
event_log = "${TMP_ROOT}/protocol-vjsx.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[engines.vjsx-transform]
kind = "vjsx"
entry = "${handler}"
runtime_profile = "node"
thread_count = 1

[transforms.convert]
kind = "vjsx"
engine = "engine:vjsx-transform"
handler = "transform.ok"

[transforms.fail]
kind = "vjsx"
engine = "engine:vjsx-transform"
handler = "transform.fail"

[transforms.throw]
kind = "vjsx"
engine = "engine:vjsx-transform"
handler = "transform.throw"

[adapters.convert]
kind = "fixed-response"
options.status = "200"
options.body = "${body}"

[adapters.fail]
kind = "fixed-response"
options.status = "200"
options.body = "should not reach egress"

[adapters.throw]
kind = "fixed-response"
options.status = "200"
options.body = "should not reach thrown egress"

[[pipelines]]
id = "protocol/vjsx"
ingress = "listener:web"
match.paths = ["/convert"]
transforms = ["transform:convert"]
egress = "adapter:convert"

[[pipelines]]
id = "protocol/vjsx-fail"
ingress = "listener:web"
match.paths = ["/fail"]
transforms = ["transform:fail"]
egress = "adapter:fail"

[[pipelines]]
id = "protocol/vjsx-throw"
ingress = "listener:web"
match.paths = ["/throw"]
transforms = ["transform:throw"]
egress = "adapter:throw"
EOF
}

write_upload_event_handler() {
    local file="$1"
    cat >"$file" <<'EOF'
function handle(ctx) {
  const event = ctx.jsonBody({});
  return ctx.json({
    ok: true,
    event: event.event,
    uploadId: event.upload_id,
    filename: event.filename,
    traceId: event.trace_id,
  }, 202);
}

globalThis.__vhttpd_handle = handle;
export default handle;
EOF
}

write_upload_event_config() {
    local file="$1"
    local port="$2"
    local handler="$3"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/upload-event.pid"

[observability]
event_log = "${TMP_ROOT}/upload-event.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[engines.upload-events]
kind = "vjsx"
entry = "${handler}"
runtime_profile = "node"
thread_count = 1

[adapters.upload]
kind = "upload"
root = "${TMP_ROOT}/uploads"
completed_pipeline = "pipeline:upload.completed"

[adapters.upload-event]
kind = "event"
topic = "upload.completed"

[transforms.upload-completed]
kind = "vjsx"
engine = "engine:upload-events"
handler = "upload.completed"

[[pipelines]]
id = "uploads.accept"
ingress = "listener:web"
match.methods = ["POST"]
match.paths = ["/upload"]
egress = "adapter:upload"

[[pipelines]]
id = "upload.completed"
ingress = "adapter:upload-event"
match.metadata = { event = "upload.completed" }
transforms = ["transform:upload-completed"]
egress = "adapter:upload-event"
EOF
}

write_generic_event_handler() {
    local file="$1"
    cat >"$file" <<'EOF'
function handle(ctx) {
  const event = ctx.jsonBody({});
  return ctx.json({
    ok: true,
    event: event.event,
    topic: event.topic,
    traceId: event.trace_id,
  }, 202);
}

globalThis.__vhttpd_handle = handle;
export default handle;
EOF
}

write_generic_event_config() {
    local file="$1"
    local port="$2"
    local handler="$3"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/generic-event.pid"

[observability]
event_log = "${TMP_ROOT}/generic-event.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[engines.events]
kind = "vjsx"
entry = "${handler}"
runtime_profile = "node"
thread_count = 1

[adapters.inventory-events]
kind = "event"
topic = "inventory.changed"

[adapters.health]
kind = "fixed-response"
options.status = "200"
options.body = "generic event ok"

[transforms.inventory-changed]
kind = "vjsx"
engine = "engine:events"
handler = "inventory.changed"

[[pipelines]]
id = "generic.health"
ingress = "listener:web"
match.paths = ["/health"]
egress = "adapter:health"

[[pipelines]]
id = "inventory.changed"
ingress = "adapter:inventory-events"
match.metadata = { event = "inventory.changed", tenant = "demo" }
transforms = ["transform:inventory-changed"]
egress = "adapter:inventory-events"
EOF
}

write_provider_runtime_config() {
    local file="$1"
    local port="$2"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/provider-runtime.pid"

[observability]
event_log = "${TMP_ROOT}/provider-runtime.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[adapters.health]
kind = "fixed-response"
options.status = "200"
options.body = "provider runtime ok"

[adapters.codex]
kind = "codex"
bool_options.enabled = true
options.url = "ws://127.0.0.1:1/vhttpd-codex"
options.model = "test-model"
int_options.reconnect_delay_ms = 60000

[adapters.feishu]
kind = "feishu-events"
bool_options.enabled = true
options.open_base_url = "http://127.0.0.1:1/open-apis"
int_options.reconnect_delay_ms = 60000
record_options = { apps = [{ id = "main", app_id = "e2e-feishu-app", app_secret = "e2e-feishu-secret", verification_token = "e2e-feishu-token", encrypt_key = "" }] }

[[pipelines]]
id = "provider/health"
ingress = "listener:web"
match.paths = ["/provider-health"]
egress = "adapter:health"

[[pipelines]]
id = "provider/codex"
ingress = "listener:web"
match.paths = ["/__codex"]
egress = "adapter:codex"

[[pipelines]]
id = "provider/feishu"
ingress = "listener:web"
match.paths = ["/callbacks/feishu"]
egress = "adapter:feishu"
EOF
}

write_provider_action_vjsx_handler() {
    local file="$1"
    local source="${2:-vjsx-provider-action}"
    cat >"$file" <<EOF
export function plugin(req) {
  const payload = JSON.parse(req.payload || "{}");
  return {
    ok: true,
    source: "${source}",
    capability: req.capability,
    provider: req.metadata.provider,
    action: req.metadata.action,
    pipeline: req.metadata.pipeline_id,
    adapter: req.metadata.adapter_id,
    receive_id: payload.receive_id || "",
    trace_id: req.trace_id,
  };
}
EOF
}

write_provider_action_runtime_config() {
    local file="$1"
    local port="$2"
    local handler="$3"
    cat >"$file" <<EOF
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "${TMP_ROOT}/provider-action-runtime.pid"

[observability]
event_log = "${TMP_ROOT}/provider-action-runtime.events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[engines.provider-runtime]
kind = "vjsx"
entry = "${handler}"
runtime_profile = "node"
thread_count = 1

[providers.feishu.runtime]
driver = "vjsx"
plugin = "feishu-provider-runtime"
engine = "engine:provider-runtime"

[providers.feishu.capabilities]
send_message = "feishu.message.send"

[adapters.provider-send]
kind = "provider-action"
provider = "feishu"
action = "send_message"
runtime_driver = "vjsx"
runtime_plugin = "feishu-provider-runtime"
runtime_engine = "engine:provider-runtime"
capability = "feishu.message.send"

[[pipelines]]
id = "provider/action"
ingress = "listener:web"
match.methods = ["POST"]
match.paths = ["/provider-action"]
egress = "adapter:provider-send"
EOF
}

write_db_runtime_config() {
    local file="$1"
    local port="$2"
    local label="${3:-db-runtime}"
    local db_host="${VHTTPD_E2E_DB_HOST:-127.0.0.1}"
    local db_port="${VHTTPD_E2E_DB_PORT:-3306}"
    local db_user="${VHTTPD_E2E_DB_USER:-root}"
    local db_password="${VHTTPD_E2E_DB_PASSWORD:-}"
    local db_name="${VHTTPD_E2E_DB_NAME:-vhttpd_e2e}"
    cat >"$file" <<EOF
[server]
host = "127.0.0.1"
port = ${port}

[files]
pid_file = "${TMP_ROOT}/${label}.pid"
event_log = "${TMP_ROOT}/${label}.events.ndjson"

[db]
enabled = true
socket = "${TMP_ROOT}/${label}.sock"
driver = "mysql"
pool_name = "default"

[db.mysql]
host = "${db_host}"
port = ${db_port}
username = "${db_user}"
password = "${db_password}"
database = "${db_name}"
pool_size = 2
idle_ping_ms = 30000
init_sql = ["SET SESSION sql_mode = ''"]

[executor]
kind = "vjsx"

[vjsx]
app_entry = "${REPO_ROOT}/examples/vjsx/hello-handler.mts"
runtime_profile = "node"
thread_count = 1

[admin]
host = "127.0.0.1"
port = 0
token = ""
EOF
}

write_db_runtime_live_probe() {
    local file="$1"
    local socket="$2"
    cat >"$file" <<EOF
<?php
declare(strict_types=1);

require_once '${REPO_ROOT}/php/package/src/VHttpd/Wire/FrameCodec.php';
require_once '${REPO_ROOT}/php/package/src/VHttpd/Wire/JsonClient.php';
require_once '${REPO_ROOT}/php/package/src/VHttpd/DbGateway/Client.php';

\$_SERVER['VHTTPD_TRACE_ID'] = 'e2e-db-runtime-live';
\$_SERVER['VHTTPD_REQUEST_ID'] = 'req-e2e-db-runtime-live';
\$client = new VHttpd\DbGateway\Client('${socket}', 'default', 1.0, 5.0);
\$ping = \$client->ping(3000);
if ((\$ping['driver'] ?? '') !== 'mysql') {
    fwrite(STDERR, "unexpected driver: " . json_encode(\$ping) . "\n");
    exit(1);
}
\$result = \$client->query('SELECT 42 AS probe_value', [], '', 3000);
\$rows = \$result['rows'] ?? [];
if (!isset(\$rows[0]['probe_value']) || (string) \$rows[0]['probe_value'] !== '42') {
    fwrite(STDERR, "unexpected query result: " . json_encode(\$result) . "\n");
    exit(2);
}
echo "OK\n";
EOF
}

write_cache_runtime_config() {
    local file="$1"
    local port="$2"
    local label="${3:-cache-runtime}"
    cat >"$file" <<EOF
[server]
host = "127.0.0.1"
port = ${port}

[files]
pid_file = "${TMP_ROOT}/${label}.pid"
event_log = "${TMP_ROOT}/${label}.events.ndjson"

[cache]
enabled = true
socket = "${TMP_ROOT}/${label}.sock"

[executor]
kind = "vjsx"

[vjsx]
app_entry = "${REPO_ROOT}/examples/vjsx/hello-handler.mts"
runtime_profile = "node"
thread_count = 1

[admin]
host = "127.0.0.1"
port = 0
token = ""
EOF
}

write_cache_runtime_probe() {
    local file="$1"
    local socket="$2"
    cat >"$file" <<EOF
<?php
declare(strict_types=1);

require_once '${REPO_ROOT}/php/package/src/VHttpd/Wire/FrameCodec.php';
require_once '${REPO_ROOT}/php/package/src/VHttpd/Wire/JsonClient.php';
require_once '${REPO_ROOT}/php/package/src/VHttpd/Cache/Client.php';

\$client = new VHttpd\Cache\Client('${socket}', 'e2e');
if (!\$client->ping()) {
    fwrite(STDERR, "ping failed\n");
    exit(1);
}
\$client->set('hello', 'world', 5000);
if (\$client->get('hello') !== 'world') {
    fwrite(STDERR, "get failed\n");
    exit(2);
}
if (!\$client->exists('hello')) {
    fwrite(STDERR, "exists failed\n");
    exit(3);
}
\$keys = \$client->keys();
sort(\$keys);
if (\$keys !== ['hello']) {
    fwrite(STDERR, 'keys failed: ' . json_encode(\$keys) . "\n");
    exit(4);
}
\$client->delete('hello');
if (\$client->exists('hello')) {
    fwrite(STDERR, "delete failed\n");
    exit(5);
}
echo "OK\n";
EOF
}

write_stream_dispatch_config() {
    local file="$1"
    local port="$2"
    cat >"$file" <<EOF
[server]
host = "127.0.0.1"
port = ${port}

[files]
pid_file = "${TMP_ROOT}/stream.pid"
event_log = "${TMP_ROOT}/stream.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 60000
pool_size = 1
stream_dispatch = true
socket = "${TMP_ROOT}/stream-worker.sock"
cmd = "php ${REPO_ROOT}/php/package/bin/vphp-worker"

[worker.env]
VHTTPD_APP = "${REPO_ROOT}/examples/stream-dispatch-app.php"

[executor]
kind = "php"

[php]
worker_entry = "${REPO_ROOT}/php/package/bin/vphp-worker"
app_entry = "${REPO_ROOT}/examples/stream-dispatch-app.php"

[admin]
host = "127.0.0.1"
port = 0
token = ""
EOF
}

write_worker_queue_app() {
    local file="$1"
    cat >"$file" <<'EOF'
<?php
declare(strict_types=1);

return static function (array $payload): array {
    $path = (string) ($payload['path'] ?? '/');
    if ($path === '/hold') {
        usleep(1200_000);
        return [
            'status' => 200,
            'headers' => ['content-type' => 'text/plain; charset=utf-8'],
            'body' => 'held',
        ];
    }
    return [
        'status' => 200,
        'headers' => ['content-type' => 'text/plain; charset=utf-8'],
        'body' => 'worker ok',
    ];
};
EOF
}

write_controlled_worker_script() {
    local file="$1"
    cat >"$file" <<'EOF'
<?php
declare(strict_types=1);

$socket = '/tmp/vhttpd-controlled-worker.sock';
for ($i = 1; $i < $argc; $i++) {
    if ($argv[$i] === '--socket' && isset($argv[$i + 1])) {
        $socket = $argv[$i + 1];
        $i++;
    }
}
if (str_starts_with($socket, 'unix://')) {
    $socket = substr($socket, 7);
}
$release = $socket . '.release';
@unlink($socket);
@unlink($release);
$server = stream_socket_server('unix://' . $socket, $errno, $errstr);
if (!$server) {
    fwrite(STDERR, "listen failed: {$errstr}\n");
    exit(1);
}

function read_exact($conn, int $bytes): string {
    $buf = '';
    while (strlen($buf) < $bytes && !feof($conn)) {
        $chunk = fread($conn, $bytes - strlen($buf));
        if ($chunk === false || $chunk === '') {
            usleep(1000);
            continue;
        }
        $buf .= $chunk;
    }
    return $buf;
}

function write_frame($conn, string $payload): void {
    $len = strlen($payload);
    fwrite($conn, pack('N', $len) . $payload);
}

while (true) {
    $conn = @stream_socket_accept($server, -1);
    if (!$conn) {
        continue;
    }
    $header = read_exact($conn, 4);
    if (strlen($header) !== 4) {
        fclose($conn);
        continue;
    }
    $size = unpack('N', $header)[1];
    $raw = read_exact($conn, $size);
    $req = json_decode($raw, true) ?: [];
    $path = (string) ($req['path'] ?? '/');
    if ($path === '/hold') {
        $deadline = microtime(true) + 60.0;
        while (!file_exists($release) && microtime(true) < $deadline) {
            usleep(10_000);
        }
        $body = 'held by controlled worker';
    } else {
        $body = 'controlled worker ok';
    }
    write_frame($conn, json_encode([
        'id' => (string) ($req['id'] ?? ''),
        'status' => 200,
        'headers' => ['content-type' => 'text/plain; charset=utf-8'],
        'body' => $body,
    ]));
    fclose($conn);
}
EOF
}

write_worker_queue_config() {
    local file="$1"
    local port="$2"
    local app_file="$3"
    cat >"$file" <<EOF
[server]
host = "127.0.0.1"
port = ${port}

[files]
pid_file = "${TMP_ROOT}/worker-queue.pid"
event_log = "${TMP_ROOT}/worker-queue.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 5000
pool_size = 1
queue_capacity = 1
queue_timeout_ms = 80
socket = "${TMP_ROOT}/worker-queue.sock"
cmd = "php ${REPO_ROOT}/php/package/bin/vphp-worker"

[worker.env]
VHTTPD_APP = "${app_file}"

[executor]
kind = "php"

[php]
worker_entry = "${REPO_ROOT}/php/package/bin/vphp-worker"
app_entry = "${app_file}"

[admin]
host = "127.0.0.1"
port = 0
token = ""
EOF
}

write_controlled_worker_queue_config() {
    local file="$1"
    local port="$2"
    local worker_script="$3"
    local worker_socket="$4"
    cat >"$file" <<EOF
[server]
host = "127.0.0.1"
port = ${port}

[files]
pid_file = "${TMP_ROOT}/controlled-worker-queue.pid"
event_log = "${TMP_ROOT}/controlled-worker-queue.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 5000
pool_size = 1
queue_capacity = 1
queue_timeout_ms = 1000
queue_poll_ms = 10
socket = "${worker_socket}"
cmd = "php ${worker_script}"

[executor]
kind = "php"

[php]
worker_entry = "${REPO_ROOT}/php/package/bin/vphp-worker"
app_entry = "${REPO_ROOT}/examples/stream-dispatch-app.php"

[admin]
host = "127.0.0.1"
port = 0
token = ""
EOF
}

test_multisite_smoke() {
    echo ""
    echo "4. Multi-site smoke"
    local blog_port
    local shop_port
    local admin_port
    blog_port="$(free_port)"
    shop_port="$(free_port)"
    admin_port="$(free_port)"
    local config="${TMP_ROOT}/multisite.toml"
    write_multisite_config "$config" "$blog_port" "$shop_port"
    start_vhttpd "multisite" --config "$config" --admin-port "$admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${blog_port}/?trace_id=e2e-blog" "blog site ok" \
        "multi-site blog listener serves blog pipeline"
    wait_http_contains "http://127.0.0.1:${shop_port}/?trace_id=e2e-shop" "shop site ok" \
        "multi-site shop listener serves shop pipeline"
    wait_http_header_contains "http://127.0.0.1:${blog_port}/" "x-vhttpd-pipeline" "blog/home" \
        "multi-site blog response exposes selected pipeline"
    wait_http_header_contains "http://127.0.0.1:${shop_port}/" "x-vhttpd-pipeline" "shop/home" \
        "multi-site shop response exposes selected pipeline"
    wait_event_contains "${TMP_ROOT}/multisite.events.ndjson" "server.started" \
        "multi-site emits server.started"
    wait_event_contains "${TMP_ROOT}/multisite.events.ndjson" "e2e-blog" \
        "multi-site blog request preserves trace id"
    wait_event_contains "${TMP_ROOT}/multisite.events.ndjson" "e2e-shop" \
        "multi-site shop request preserves trace id"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"blog/home"' \
        "multi-site admin plan exposes blog pipeline"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"shop/home"' \
        "multi-site admin plan exposes shop pipeline"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"listeners"' \
        "multi-site admin plan exposes listeners"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime" '"listener_id":"blog"' \
        "multi-site admin runtime exposes owner listener"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime" '"pipeline_id":"blog/home"' \
        "multi-site admin runtime exposes owner pipeline route"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime" '"listener_id":"shop"' \
        "multi-site admin runtime exposes secondary listener"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime" '"pipeline_id":"shop/home"' \
        "multi-site admin runtime exposes secondary pipeline route"
}

test_wordpress_v2_smoke() {
    echo ""
    echo "5. WordPress V2 smoke"
    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local wp_root="${TMP_ROOT}/wordpress-root"
    mkdir -p "${wp_root}/wp-content/themes/demo" "${wp_root}/wp-includes/js"
    printf '/* vhttpd wordpress smoke */\nbody{color:#123456;}\n' >"${wp_root}/wp-content/themes/demo/style.css"
    printf 'window.__vhttpdWordPressSmoke = true;\n' >"${wp_root}/wp-includes/js/demo.js"
    printf '<?php // protected bootstrap placeholder\n' >"${wp_root}/wp-load.php"

    local config="${TMP_ROOT}/wordpress-v2.toml"
    write_wordpress_v2_smoke_config "$config" "$port" "$wp_root"
    start_vhttpd "wordpress-v2" --config "$config" --admin-port "$admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${port}/meta?trace_id=e2e-wordpress-v2-meta" \
        '"framework":"wordpress"' "wordpress v2 worker serves framework metadata"
    wait_http_contains "http://127.0.0.1:${port}/meta?trace_id=e2e-wordpress-v2-installed" \
        '"installed":false' "wordpress v2 worker reports missing wp-config without DB"
    wait_http_header_contains "http://127.0.0.1:${port}/meta?cache_case=anon&trace_id=e2e-wordpress-v2-cache" \
        "x-vhttpd-cache" "store" "wordpress v2 response cache stores anonymous worker response"
    wait_http_header_contains "http://127.0.0.1:${port}/meta?cache_case=anon&trace_id=e2e-wordpress-v2-cache" \
        "x-vhttpd-cache" "hit" "wordpress v2 response cache hits anonymous worker response"
    wait_http_header_contains_with_cookie "http://127.0.0.1:${port}/meta?cache_case=anon&trace_id=e2e-wordpress-v2-cache" \
        "wordpress_test_cookie=WP%20Cookie%20check" "x-vhttpd-cache" "hit" \
        "wordpress v2 response cache ignores wordpress_test_cookie"
    wait_http_header_contains_with_cookie "http://127.0.0.1:${port}/meta?cache_case=login&trace_id=e2e-wordpress-v2-cache-bypass" \
        "wordpress_logged_in_abc=token" "x-vhttpd-cache" "bypass" \
        "wordpress v2 response cache bypasses logged-in cookie"
    wait_http_header_contains_with_cookie "http://127.0.0.1:${port}/meta?cache_case=login&trace_id=e2e-wordpress-v2-cache-bypass" \
        "wordpress_logged_in_abc=token" "x-vhttpd-cache-reason" "cookie:wordpress_logged_in_abc" \
        "wordpress v2 response cache reports logged-in bypass reason"
    wait_http_contains "http://127.0.0.1:${port}/wp-content/themes/demo/style.css?trace_id=e2e-wordpress-v2-asset" \
        'vhttpd wordpress smoke' "wordpress v2 static pipeline serves wp-content asset"
    wait_http_header_contains "http://127.0.0.1:${port}/wp-content/themes/demo/style.css" \
        "cache-control" "public, max-age=3600" "wordpress v2 static asset policy applies cache-control"
    wait_http_contains "http://127.0.0.1:${port}/wp-includes/js/demo.js" \
        '__vhttpdWordPressSmoke' "wordpress v2 static pipeline serves wp-includes asset"
    wait_http_status_contains "http://127.0.0.1:${port}/wp-load.php?trace_id=e2e-wordpress-v2-deny" \
        "403" "Forbidden" "wordpress v2 security pipeline denies core php file"
    wait_http_status_contains "http://127.0.0.1:${port}/?trace_id=e2e-wordpress-v2-home" \
        "302" "" "wordpress v2 front page reaches worker redirect when uninstalled"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"wordpress.front-page"' \
        "wordpress v2 admin plan exposes front page pipeline"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"assets.wordpress-directories"' \
        "wordpress v2 admin plan exposes wordpress asset pipeline"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"security.deny-core-files"' \
        "wordpress v2 admin plan exposes security pipeline"
    wait_event_contains "${TMP_ROOT}/wordpress-v2.events.ndjson" "e2e-wordpress-v2-meta" \
        "wordpress v2 worker request preserves trace id"
    wait_event_contains "${TMP_ROOT}/wordpress-v2.events.ndjson" "e2e-wordpress-v2-asset" \
        "wordpress v2 static request preserves trace id"
    wait_event_contains "${TMP_ROOT}/wordpress-v2.events.ndjson" '"cache":"store"' \
        "wordpress v2 cache store is observable in event log"
    wait_event_contains "${TMP_ROOT}/wordpress-v2.events.ndjson" '"cache":"hit"' \
        "wordpress v2 cache hit is observable in event log"
    wait_event_contains "${TMP_ROOT}/wordpress-v2.events.ndjson" '"cache_reason":"cookie:wordpress_logged_in_abc"' \
        "wordpress v2 cache bypass reason is observable in event log"
}

test_wordpress_installed_v2_smoke() {
    if [[ -z "${VHTTPD_E2E_WP_ROOT:-}" ]]; then
        ok "wordpress installed v2 smoke skipped unless VHTTPD_E2E_WP_ROOT is set"
        return 0
    fi
    if [[ ! -f "${VHTTPD_E2E_WP_ROOT}/wp-config.php" ]] || [[ ! -f "${VHTTPD_E2E_WP_ROOT}/wp-load.php" ]]; then
        ko "wordpress installed v2 smoke root is a WordPress install"
        echo "    VHTTPD_E2E_WP_ROOT=${VHTTPD_E2E_WP_ROOT}"
        return 1
    fi

    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local config="${TMP_ROOT}/wordpress-installed-v2.toml"
    if [[ "${VHTTPD_E2E_DB_LIVE:-0}" != "1" ]]; then
        ok "wordpress installed v2 smoke skipped unless VHTTPD_E2E_DB_LIVE=1"
        return 0
    fi
    write_wordpress_v2_smoke_config "$config" "$port" "$VHTTPD_E2E_WP_ROOT" "wordpress-installed-v2" "1"
    start_vhttpd "wordpress-installed-v2" --config "$config" --admin-port "$admin_port" >/dev/null
    local base_url="http://127.0.0.1:${port}"
    local canonical_base="${VHTTPD_E2E_WP_SITE_URL:-http://127.0.0.1:8080}"
    canonical_base="${canonical_base%/}"
    wait_http_contains "${base_url}/meta?trace_id=e2e-wordpress-installed-meta" \
        '"framework":"wordpress"' "wordpress installed v2 serves metadata"
    wait_http_contains "${base_url}/meta?trace_id=e2e-wordpress-installed-meta" \
        '"site_name":' "wordpress installed v2 exposes site metadata"
    wait_http_status_contains "${base_url}/?trace_id=e2e-wordpress-installed-home" \
        "301" "Redirecting to ${canonical_base}/" \
        "wordpress installed v2 front page reaches WordPress canonical redirect"
    wait_http_status_contains "${base_url}/cart?trace_id=e2e-wordpress-installed-cart" \
        "301" "Redirecting to ${canonical_base}/cart" \
        "wordpress installed v2 WooCommerce cart reaches WordPress canonical redirect"
    wait_http_status_contains "${base_url}/checkout?trace_id=e2e-wordpress-installed-checkout" \
        "301" "Redirecting to ${canonical_base}/checkout" \
        "wordpress installed v2 WooCommerce checkout reaches WordPress canonical redirect"
    wait_http_status_contains "${base_url}/wp-json/?trace_id=e2e-wordpress-installed-rest" \
        "301" "Redirecting to ${canonical_base}/wp-json/" \
        "wordpress installed v2 REST index reaches WordPress canonical redirect"
    wait_http_header_contains "${base_url}/wp-includes/css/dist/block-library/style.min.css?trace_id=e2e-wordpress-installed-asset" \
        "cache-control" "max-age=3600" \
        "wordpress installed v2 serves core admin/static asset through static pipeline"
    wait_http_header_contains_with_cookie "${base_url}/meta?trace_id=e2e-wordpress-installed-cache-bypass" \
        "wordpress_logged_in_e2e=token" "x-vhttpd-cache" "bypass" \
        "wordpress installed v2 bypasses cache for logged-in cookie"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"wordpress.front-page"' \
        "wordpress installed v2 admin plan exposes dynamic pipeline"
    wait_event_contains "${TMP_ROOT}/wordpress-installed-v2.events.ndjson" "e2e-wordpress-installed-cart" \
        "wordpress installed v2 cart request preserves trace id"
    wait_event_contains "${TMP_ROOT}/wordpress-installed-v2.events.ndjson" "e2e-wordpress-installed-rest" \
        "wordpress installed v2 REST request preserves trace id"
}

test_protocol_conversion_smoke() {
    echo ""
    echo "6. Protocol conversion smoke"
    local native_port
    local vjsx_port
    local native_admin_port
    local vjsx_admin_port
    native_port="$(free_port)"
    vjsx_port="$(free_port)"
    native_admin_port="$(free_port)"
    vjsx_admin_port="$(free_port)"
    local handler="${TMP_ROOT}/protocol-transformer.mts"
    local next_handler="${TMP_ROOT}/protocol-transformer-next.mts"
    local native_config="${TMP_ROOT}/protocol-native.toml"
    local vjsx_config="${TMP_ROOT}/protocol-vjsx.toml"
    local next_vjsx_config="${TMP_ROOT}/protocol-vjsx-next.toml"
    write_protocol_transform_handler "$handler"
    write_protocol_transform_handler "$next_handler"
    write_protocol_native_config "$native_config" "$native_port"
    write_protocol_vjsx_config "$vjsx_config" "$vjsx_port" "$handler"
    write_protocol_vjsx_config "$next_vjsx_config" "$vjsx_port" "$next_handler" "vjsx transform next ok"

    start_vhttpd "protocol-native" --config "$native_config" --admin-port "$native_admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${native_port}/convert?trace_id=e2e-proto-native" \
        "native transform ok" "protocol native transform request succeeds"
    wait_event_contains "${TMP_ROOT}/protocol-native.events.ndjson" "e2e-proto-native" \
        "protocol native transform preserves trace id"
    wait_http_contains "http://127.0.0.1:${native_admin_port}/admin/runtime/transformers" '"native_count":1' \
        "protocol native admin snapshot exposes native transformer"

    start_vhttpd "protocol-vjsx" --config "$vjsx_config" --admin-port "$vjsx_admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${vjsx_port}/convert?trace_id=e2e-proto-vjsx" \
        "vjsx transform ok" "protocol vjsx transform request succeeds"
    wait_http_status_contains "http://127.0.0.1:${vjsx_port}/fail?trace_id=e2e-proto-fail" \
        "500" "" "protocol vjsx transform failure is reported"
    wait_http_header_contains "http://127.0.0.1:${vjsx_port}/fail?trace_id=e2e-proto-fail-header" \
        "x-vhttpd-error-class" "vjsx_transformer_failed" \
        "protocol vjsx transform failure exposes error class"
    wait_http_status_contains "http://127.0.0.1:${vjsx_port}/throw?trace_id=e2e-proto-throw" \
        "502" "" "protocol vjsx transform exception is reported"
    wait_event_contains "${TMP_ROOT}/protocol-vjsx.events.ndjson" "e2e-proto-vjsx" \
        "protocol vjsx transform preserves trace id"
    wait_event_contains "${TMP_ROOT}/protocol-vjsx.events.ndjson" "e2e-proto-fail" \
        "protocol vjsx transform failure preserves trace id"
    wait_event_contains "${TMP_ROOT}/protocol-vjsx.events.ndjson" "e2e-proto-throw" \
        "protocol vjsx transform exception preserves trace id"
    wait_event_contains "${TMP_ROOT}/protocol-vjsx.events.ndjson" "inproc_vjsx_executor_handler_failed" \
        "protocol vjsx transform exception records handler failure"
    wait_http_contains "http://127.0.0.1:${vjsx_admin_port}/admin/runtime/transformers" '"vjsx_count":3' \
        "protocol vjsx admin snapshot exposes vjsx transformers"
    wait_http_contains "http://127.0.0.1:${vjsx_admin_port}/admin/runtime/plan" '"protocol/vjsx-throw"' \
        "protocol admin plan exposes transform pipeline"
    wait_http_contains "http://127.0.0.1:${vjsx_admin_port}/admin/runtime/plan/replacement?config=${next_vjsx_config}" '"reload_transforms":\["convert","fail","throw"\]' \
        "protocol vjsx replacement preview reloads transforms"
    wait_http_post_contains "http://127.0.0.1:${vjsx_admin_port}/admin/runtime/plan/replacement/apply?config=${next_vjsx_config}" \
        '{}' '"status":"applied"' \
        "protocol vjsx replacement apply is lightweight"
    wait_event_contains "${TMP_ROOT}/protocol-vjsx.events.ndjson" "runtime.plan.replaced" \
        "protocol vjsx replacement emits plan replaced event"
    wait_http_contains "http://127.0.0.1:${vjsx_port}/convert?trace_id=e2e-proto-vjsx-replaced" \
        "vjsx transform next ok" "protocol vjsx pipeline uses replaced transform runtime"
    wait_event_contains "${TMP_ROOT}/protocol-vjsx.events.ndjson" "e2e-proto-vjsx-replaced" \
        "protocol vjsx replaced request preserves trace id"
}

test_v1_compat_smoke() {
    echo ""
    echo "1. V1 compatibility smoke"
    local port
    port="$(free_port)"
    local config="${TMP_ROOT}/v1-hello.toml"
    write_v1_hello_config "$config" "$port"
    start_vhttpd "v1-hello" --config "$config" >/dev/null
    wait_http_contains "http://127.0.0.1:${port}/hello?name=v1" '"name":"v1"' \
        "v1 compatibility config serves vjsx request"
    wait_event_contains "${TMP_ROOT}/v1.events.ndjson" "server.started" \
        "v1 compatibility emits server.started"
}

test_v2_simple_site_smoke() {
    echo ""
    echo "2. V2 simple site smoke"
    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local config="${TMP_ROOT}/v2-hello.toml"
    write_v2_hello_config "$config" "$port"
    start_vhttpd "v2-hello" --config "$config" --admin-port "$admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${port}/hello?name=v2" '"name":"v2"' \
        "v2 config serves pipeline request"
    wait_http_contains "http://127.0.0.1:${port}/hello?trace_id=e2e-v2" '"traceId":"e2e-v2"' \
        "v2 request preserves trace id"
}

test_v2_diagnostics_smoke() {
    echo ""
    echo "3. V2 diagnostics smoke"
    local case_name
    local config
    local port
    for case_name in adapter transform listener resource; do
        port="$(free_port)"
        config="${TMP_ROOT}/missing-${case_name}.toml"
        write_v2_missing_reference_config "$config" "$port" "$case_name"
        expect_vhttpd_config_failure "missing-${case_name}" "$config" "runtime_plan_unresolved_ref" \
            "v2 diagnostics reject missing ${case_name} reference"
    done
}

test_relay_smoke() {
    echo ""
    echo "7. Relay smoke"
    local public_port
    local relay_port
    local agent_port
    local public_admin_port
    local agent_admin_port
    public_port="$(free_port)"
    relay_port="$(free_port)"
    agent_port="$(free_port)"
    public_admin_port="$(free_port)"
    agent_admin_port="$(free_port)"
    local public_config="${TMP_ROOT}/relay-public.toml"
    local next_public_config="${TMP_ROOT}/relay-public-next.toml"
    local agent_config="${TMP_ROOT}/relay-agent.toml"
    write_relay_public_config "$public_config" "$public_port" "$relay_port"
    write_relay_public_config "$next_public_config" "$public_port" "$relay_port" "/vhttpd/relay-next"
    write_relay_agent_config "$agent_config" "$agent_port" "$relay_port"
    start_vhttpd "relay-public" --config "$public_config" --admin-port "$public_admin_port" >/dev/null
    wait_event_contains "${TMP_ROOT}/relay-public.events.ndjson" "server.started" \
        "relay public runtime starts"

    local agent_pid
    agent_pid="$(start_vhttpd "relay-agent" --config "$agent_config" --admin-port "$agent_admin_port")"
    wait_event_contains "${TMP_ROOT}/relay-agent.events.ndjson" "server.started" \
        "relay agent runtime starts"
    wait_http_contains "http://127.0.0.1:${public_port}/relay?trace_id=e2e-relay" "relay agent ok" \
        "relay request reaches local agent and returns"
    wait_event_contains "${TMP_ROOT}/relay-public.events.ndjson" "response_completion.completed" \
        "relay wait completion records completed response event"
    wait_event_contains "${TMP_ROOT}/relay-public.events.ndjson" '"completion_mode":"wait"' \
        "relay wait completion records configured completion mode"
    wait_http_contains "http://127.0.0.1:${public_admin_port}/admin/runtime" '"descriptor_count":1' \
        "relay public admin runtime exposes relay descriptor"
    wait_http_contains "http://127.0.0.1:${public_admin_port}/admin/runtime" '"carrier_count":1' \
        "relay public admin runtime exposes carrier"
    wait_http_contains "http://127.0.0.1:${agent_admin_port}/admin/runtime/plan" '"relay/local-response"' \
        "relay agent admin plan exposes relay pipeline"
    wait_http_contains "http://127.0.0.1:${public_admin_port}/admin/runtime/plan/replacement?config=${next_public_config}" '"strategy":"relay_reload_required"' \
        "relay replacement preview requires relay reload"
    wait_http_post_status_contains "http://127.0.0.1:${public_admin_port}/admin/runtime/plan/replacement/apply?config=${next_public_config}" \
        '{}' "409" '"runtime_plan_replacement_requires_relay_reload"' \
        "relay replacement apply rejects unsupported hot reload"
    kill "$agent_pid" >/dev/null 2>&1 || true
    wait "$agent_pid" >/dev/null 2>&1 || true
    wait_http_status_contains "http://127.0.0.1:${public_port}/relay?trace_id=e2e-relay-disconnected" "503" "" \
        "relay request fails fast while agent is disconnected"
    wait_event_contains "${TMP_ROOT}/relay-public.events.ndjson" "e2e-relay-disconnected" \
        "relay disconnected failure preserves trace id"
    wait_event_contains "${TMP_ROOT}/relay-public.events.ndjson" "relay_carrier_unavailable" \
        "relay disconnected failure records unavailable carrier"
    agent_pid="$(start_vhttpd "relay-agent-restarted" --config "$agent_config" --admin-port "$agent_admin_port")"
    wait_http_status_contains "http://127.0.0.1:${agent_port}/health" "200" "" \
        "relay agent restarts after disconnect"
    wait_http_contains "http://127.0.0.1:${public_port}/relay?trace_id=e2e-relay-reconnect" "relay agent ok" \
        "relay request recovers after agent reconnect"
}

test_stream_dispatch_smoke() {
    echo ""
    echo "13. Stream dispatch smoke"
    local port
    port="$(free_port)"
    local config="${TMP_ROOT}/stream-dispatch.toml"
    write_stream_dispatch_config "$config" "$port"
    start_vhttpd "stream-dispatch" --config "$config" >/dev/null
    wait_http_contains "http://127.0.0.1:${port}/meta" '"strategy":"dispatch"' \
        "stream dispatch config serves metadata"
    wait_http_contains "http://127.0.0.1:${port}/events/sse" "stream complete" \
        "stream dispatch emits SSE through worker open/next"
    wait_event_contains "${TMP_ROOT}/stream.events.ndjson" "server.started" \
        "stream dispatch emits server.started"
}

test_provider_runtime_smoke() {
    echo ""
    echo "8. Provider runtime smoke"
    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local config="${TMP_ROOT}/provider-runtime.toml"
    write_provider_runtime_config "$config" "$port"
    start_vhttpd "provider-runtime" --config "$config" --admin-port "$admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${port}/provider-health?trace_id=e2e-provider-health" \
        "provider runtime ok" "provider runtime config serves baseline request"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/providers" '"codex"' \
        "provider admin lists codex provider"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/providers" '"feishu"' \
        "provider admin lists feishu provider"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/providers/specs" '"name":"codex"' \
        "provider admin specs expose codex registration"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/providers/specs" '"name":"feishu"' \
        "provider admin specs expose feishu registration"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/codex" '"enabled":true' \
        "provider admin runtime exposes codex enabled state"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/codex" 'ws://127.0.0.1:1/vhttpd-codex' \
        "provider admin runtime exposes codex configured url"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/feishu" '"enabled":true' \
        "provider admin runtime exposes feishu enabled state"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/feishu" '"app_count":1' \
        "provider admin runtime exposes feishu app count"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/feishu" '"open_base_url":"http://127.0.0.1:1/open-apis"' \
        "provider admin runtime exposes feishu configured base url"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/providers/runtimes" '"name":"codex"' \
        "provider admin runtimes expose codex provider"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/providers/runtimes" '"name":"feishu"' \
        "provider admin runtimes expose feishu provider"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"provider/codex"' \
        "provider admin plan exposes provider pipeline"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/plan" '"provider/feishu"' \
        "provider admin plan exposes feishu provider pipeline"
    local action_port
    action_port="$(free_port)"
    local action_handler="${TMP_ROOT}/provider-action-runtime.mts"
    local next_action_handler="${TMP_ROOT}/provider-action-runtime-next.mts"
    local action_config="${TMP_ROOT}/provider-action-runtime.toml"
    local next_action_config="${TMP_ROOT}/provider-action-runtime-next.toml"
    write_provider_action_vjsx_handler "$action_handler"
    write_provider_action_vjsx_handler "$next_action_handler" "vjsx-provider-action-next"
    write_provider_action_runtime_config "$action_config" "$action_port" "$action_handler"
    write_provider_action_runtime_config "$next_action_config" "$action_port" "$next_action_handler"
    start_vhttpd "provider-action-runtime" --config "$action_config" >/dev/null
    wait_http_post_contains "http://127.0.0.1:${action_port}/provider-action?trace_id=e2e-provider-action" \
        '{"receive_id":"chat-e2e"}' '"source":"vjsx-provider-action"' \
        "provider-action pipeline dispatches configured vjsx provider runtime"
    wait_http_post_contains "http://127.0.0.1:${action_port}/provider-action?trace_id=e2e-provider-action-capability" \
        '{"receive_id":"chat-e2e"}' '"capability":"feishu.message.send"' \
        "provider-action vjsx runtime receives configured capability"
    wait_http_contains "http://127.0.0.1:${action_port}/admin/runtime/plan" '"providers":{"feishu"' \
        "provider-action admin plan exposes provider runtime entity"
    wait_http_contains "http://127.0.0.1:${action_port}/admin/runtime/plan" '"plugin":"feishu-provider-runtime"' \
        "provider-action admin plan exposes provider runtime plugin"
    wait_http_contains "http://127.0.0.1:${action_port}/admin/runtime/plan/replacement?config=${next_action_config}" '"reload_providers":\["feishu"\]' \
        "provider-action replacement preview reloads provider runtime"
    wait_http_post_contains "http://127.0.0.1:${action_port}/admin/runtime/plan/replacement/apply?config=${next_action_config}" \
        '{}' '"status":"applied"' \
        "provider-action replacement apply is lightweight"
    wait_http_post_contains "http://127.0.0.1:${action_port}/provider-action?trace_id=e2e-provider-action-replaced" \
        '{"receive_id":"chat-e2e"}' '"source":"vjsx-provider-action-next"' \
        "provider-action pipeline uses replaced vjsx provider runtime"
    local data_plane_port
    data_plane_port="$(free_port)"
    local data_plane_config="${TMP_ROOT}/provider-runtime-dataplane.toml"
    write_provider_runtime_config "$data_plane_config" "$data_plane_port"
    start_vhttpd "provider-runtime-dataplane" --config "$data_plane_config" >/dev/null
    wait_http_contains "http://127.0.0.1:${data_plane_port}/admin/runtime/feishu" '"app_count":1' \
        "provider data-plane admin exposes feishu runtime"
    local upsert_body
    upsert_body='{"provider":"codex","instance":"project_demo","config_json":"{\"url\":\"ws://127.0.0.1:1/project-demo\",\"model\":\"e2e-model\"}","desired_state":"connected"}'
    wait_http_post_contains "http://127.0.0.1:${admin_port}/admin/runtime/provider-instances?trace_id=e2e-provider-upsert" \
        "$upsert_body" '"instance":"project_demo"' \
        "provider admin can upsert dynamic codex instance"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/provider-instances?provider=codex" \
        '"config_fields":\["model","url"\]' \
        "provider instance snapshot exposes config field names"
    local update_body
    update_body='{"provider":"codex","instance":"project_demo","config_json":"{\"url\":\"ws://127.0.0.1:1/project-demo\",\"model\":\"e2e-model\"}","desired_state":"paused"}'
    wait_http_post_contains "http://127.0.0.1:${admin_port}/admin/runtime/provider-instances?trace_id=e2e-provider-update" \
        "$update_body" '"desired_state":"paused"' \
        "provider admin can update dynamic instance desired state"
    wait_event_contains "${TMP_ROOT}/provider-runtime.events.ndjson" "e2e-provider-health" \
        "provider runtime request preserves trace id"
    wait_event_contains "${TMP_ROOT}/provider-runtime.events.ndjson" "e2e-provider-upsert" \
        "provider instance upsert preserves trace id"
}

test_db_runtime_smoke() {
    echo ""
    echo "9. DB runtime smoke"
    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local config="${TMP_ROOT}/db-runtime.toml"
    local probe="${TMP_ROOT}/db-runtime-live-probe.php"
    local socket="${TMP_ROOT}/db-runtime.sock"
    write_db_runtime_config "$config" "$port"
    write_db_runtime_live_probe "$probe" "$socket"
    start_vhttpd "db-runtime" --config "$config" --admin-port "$admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${port}/hello?trace_id=e2e-db-health" '"name":"world"' \
        "db runtime config serves baseline request"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/db?trace_id=e2e-db-runtime" \
        '"enabled":true' "db admin runtime exposes enabled state"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/db" \
        'db-runtime.sock' "db admin runtime exposes socket"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/db" \
        '"driver":"mysql"' "db admin runtime exposes driver"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/db" \
        '"idle_ping_ms":30000' "db admin runtime exposes idle ping"
    local data_plane_port
    data_plane_port="$(free_port)"
    local data_plane_config="${TMP_ROOT}/db-runtime-dataplane.toml"
    write_db_runtime_config "$data_plane_config" "$data_plane_port" "db-runtime-dataplane"
    start_vhttpd "db-runtime-dataplane" --config "$data_plane_config" >/dev/null
    wait_http_contains "http://127.0.0.1:${data_plane_port}/admin/runtime/db" \
        '"enabled":true' "db data-plane admin exposes runtime"
    wait_event_contains "${TMP_ROOT}/db-runtime.events.ndjson" "e2e-db-health" \
        "db runtime request preserves trace id"
    wait_event_contains "${TMP_ROOT}/db-runtime.events.ndjson" "server.started" \
        "db runtime emits server.started"
    if [[ "${VHTTPD_E2E_DB_LIVE:-0}" == "1" ]]; then
        if php "$probe" >/dev/null 2>"${TMP_ROOT}/db-runtime-live-probe.err"; then
            ok "db runtime socket serves live mysql query"
        else
            ko "db runtime socket serves live mysql query"
            echo "    probe stderr:"
            sed 's/^/      /' "${TMP_ROOT}/db-runtime-live-probe.err" 2>/dev/null || true
            print_logs
            return 1
        fi
        wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/db" \
            '"total_queries":1' "db admin runtime records live query count"
        wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/db" \
            'e2e-db-runtime-live' "db admin runtime records live query trace id"
    else
        ok "db live query smoke skipped unless VHTTPD_E2E_DB_LIVE=1"
    fi
}

test_cache_runtime_smoke() {
    echo ""
    echo "10. Cache runtime smoke"
    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local config="${TMP_ROOT}/cache-runtime.toml"
    local probe="${TMP_ROOT}/cache-runtime-probe.php"
    local socket="${TMP_ROOT}/cache-runtime.sock"
    write_cache_runtime_config "$config" "$port"
    write_cache_runtime_probe "$probe" "$socket"
    start_vhttpd "cache-runtime" --config "$config" --admin-port "$admin_port" >/dev/null
    wait_http_contains "http://127.0.0.1:${port}/hello?trace_id=e2e-cache-health" '"name":"world"' \
        "cache runtime config serves baseline request"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/cache" \
        '"enabled":true' "cache admin runtime exposes enabled state"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/cache" \
        '"started":true' "cache admin runtime exposes started state"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/cache" \
        'cache-runtime.sock' "cache admin runtime exposes socket"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/cache" \
        '"keys":0' "cache admin runtime exposes key count"
    local data_plane_port
    data_plane_port="$(free_port)"
    local data_plane_config="${TMP_ROOT}/cache-runtime-dataplane.toml"
    write_cache_runtime_config "$data_plane_config" "$data_plane_port" "cache-runtime-dataplane"
    start_vhttpd "cache-runtime-dataplane" --config "$data_plane_config" >/dev/null
    wait_http_contains "http://127.0.0.1:${data_plane_port}/admin/runtime/cache" \
        '"enabled":true' "cache data-plane admin exposes runtime"
    if php "$probe" >/dev/null 2>"${TMP_ROOT}/cache-runtime-probe.err"; then
        ok "cache runtime socket serves php cache client operations"
    else
        ko "cache runtime socket serves php cache client operations"
        echo "    probe stderr:"
        sed 's/^/      /' "${TMP_ROOT}/cache-runtime-probe.err" 2>/dev/null || true
        print_logs
        return 1
    fi
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime/cache" \
        '"total_ops":7' "cache admin runtime exposes operation count"
    wait_event_contains "${TMP_ROOT}/cache-runtime.events.ndjson" "e2e-cache-health" \
        "cache runtime request preserves trace id"
    wait_event_contains "${TMP_ROOT}/cache-runtime.events.ndjson" "server.started" \
        "cache runtime emits server.started"
}

test_upload_event_pipeline_smoke() {
    echo ""
    echo "11. Upload event pipeline smoke"
    local port
    port="$(free_port)"
    local handler="${TMP_ROOT}/upload-event-handler.mts"
    local config="${TMP_ROOT}/upload-event.toml"
    write_upload_event_handler "$handler"
    write_upload_event_config "$config" "$port" "$handler"
    start_vhttpd "upload-event" --config "$config" >/dev/null
    wait_http_text_post_contains "http://127.0.0.1:${port}/upload?trace_id=e2e-upload-event" \
        "hello upload event" '"event":"upload.completed"' \
        "upload event route accepts upload"
    wait_event_contains "${TMP_ROOT}/upload-event.events.ndjson" "upload.completed" \
        "upload event emits completion event"
    wait_event_contains "${TMP_ROOT}/upload-event.events.ndjson" "upload.completed.dispatch" \
        "upload event pipeline dispatches transform"
    wait_event_contains "${TMP_ROOT}/upload-event.events.ndjson" "transform:upload-completed" \
        "upload event dispatch records transform id"
    wait_event_contains "${TMP_ROOT}/upload-event.events.ndjson" "e2e-upload-event" \
        "upload event preserves trace id"
}

test_generic_event_pipeline_smoke() {
    echo ""
    echo "12. Generic event pipeline smoke"
    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local handler="${TMP_ROOT}/generic-event-handler.mts"
    local config="${TMP_ROOT}/generic-event.toml"
    write_generic_event_handler "$handler"
    write_generic_event_config "$config" "$port" "$handler"
    start_vhttpd "generic-event" --config "$config" --admin-port "$admin_port" >/dev/null
    local body
    body='{"ingress":"adapter:inventory-events","topic":"inventory","name":"inventory.changed","metadata":{"tenant":"demo"},"data":"{\"sku\":\"SKU-1\",\"stock\":7}"}'
    wait_http_post_contains "http://127.0.0.1:${admin_port}/admin/runtime/events?trace_id=e2e-generic-event" \
        "$body" '"pipeline":"inventory.changed"' \
        "generic event admin dispatch selects event pipeline"
    wait_event_contains "${TMP_ROOT}/generic-event.events.ndjson" "runtime.event.dispatch" \
        "generic event emits dispatch observation"
    wait_event_contains "${TMP_ROOT}/generic-event.events.ndjson" "transform:inventory-changed" \
        "generic event records transform id"
    wait_event_contains "${TMP_ROOT}/generic-event.events.ndjson" "e2e-generic-event" \
        "generic event preserves trace id"
}

test_worker_queue_smoke() {
    echo ""
    echo "14. Worker queue smoke"
    local port
    local admin_port
    port="$(free_port)"
    admin_port="$(free_port)"
    local app_file="${TMP_ROOT}/worker-queue-app.php"
    local config="${TMP_ROOT}/worker-queue.toml"
    local hold_body="${TMP_ROOT}/worker-queue-hold.body"
    write_worker_queue_app "$app_file"
    write_worker_queue_config "$config" "$port" "$app_file"
    start_vhttpd "worker-queue" --config "$config" --admin-port "$admin_port" >/dev/null
    wait_event_contains "${TMP_ROOT}/worker-queue.events.ndjson" "server.started" \
        "worker queue runtime starts"
    wait_http_contains "http://127.0.0.1:${port}/fast" "worker ok" \
        "worker queue runtime serves baseline request"

    curl -fsS --max-time 3 "http://127.0.0.1:${port}/hold?trace_id=e2e-worker-hold" >"$hold_body" 2>/dev/null &
    local hold_pid=$!
    sleep 0.35
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/workers" '"inflight_requests":1' \
        "worker admin snapshot exposes busy worker"
    wait "$hold_pid" >/dev/null 2>&1 || true
    if grep -q "held" "$hold_body"; then
        ok "worker busy request completes after admin observation"
    else
        ko "worker busy request completes after admin observation"
        echo "    hold body:"
        sed 's/^/      /' "$hold_body" 2>/dev/null || true
        print_logs
        return 1
    fi
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime" '"queue_capacity":1' \
        "worker admin runtime exposes queue capacity"
    wait_http_contains "http://127.0.0.1:${admin_port}/admin/runtime" '"queue_timeout_ms":80' \
        "worker admin runtime exposes queue timeout"
    wait_event_contains "${TMP_ROOT}/worker-queue.events.ndjson" "e2e-worker-hold" \
        "worker busy request preserves trace id"

    local controlled_port
    local controlled_admin_port
    controlled_port="$(free_port)"
    controlled_admin_port="$(free_port)"
    local controlled_worker="${TMP_ROOT}/controlled-worker.php"
    local controlled_config="${TMP_ROOT}/controlled-worker-queue.toml"
    local controlled_hold_body="${TMP_ROOT}/controlled-worker-hold.body"
    local controlled_queued_body="${TMP_ROOT}/controlled-worker-queued.body"
    local controlled_timeout_hold_body="${TMP_ROOT}/controlled-worker-timeout-hold.body"
    local controlled_socket="/tmp/vhq-$$-${RANDOM}.sock"
    local controlled_release="${controlled_socket}.release"
    write_controlled_worker_script "$controlled_worker"
    write_controlled_worker_queue_config "$controlled_config" "$controlled_port" "$controlled_worker" "$controlled_socket"
    rm -f "$controlled_release"
    start_vhttpd "controlled-worker-queue" --config "$controlled_config" --admin-port "$controlled_admin_port" >/dev/null
    local controlled_base_url="http://127.0.0.1:${controlled_port}"
    wait_http_contains "${controlled_base_url}/fast" "controlled worker ok" \
        "controlled worker queue runtime serves baseline request"
    wait_http_contains "http://127.0.0.1:${controlled_admin_port}/admin/runtime" '"queue_timeout_ms":1000' \
        "controlled worker admin runtime exposes queue timeout"

    curl -fsS --max-time 20 "${controlled_base_url}/hold?trace_id=e2e-worker-controlled-hold" >"$controlled_hold_body" 2>/dev/null &
    local controlled_hold_pid=$!
    wait_http_contains "http://127.0.0.1:${controlled_admin_port}/admin/workers" '"inflight_requests":1' \
        "controlled worker admin snapshot exposes busy worker"
    curl -fsS --max-time 20 "${controlled_base_url}/fast?trace_id=e2e-worker-queued-success" >"$controlled_queued_body" 2>/dev/null &
    local controlled_queued_pid=$!
    wait_http_contains "http://127.0.0.1:${controlled_admin_port}/admin/runtime" '"queue_depth":1' \
        "controlled worker admin runtime exposes queued request"
    expect_http_status_contains_once "${controlled_base_url}/fast?trace_id=e2e-worker-queue-full" \
        "503" "" "controlled worker third request is rejected when queue is full" "3"
    wait_http_header_contains "${controlled_base_url}/fast?trace_id=e2e-worker-queue-full-header" \
        "x-vhttpd-error-class" "worker_queue_full" \
        "controlled worker queue full exposes error class"
    : >"$controlled_release"
    wait "$controlled_queued_pid" >/dev/null 2>&1 || true
    wait "$controlled_hold_pid" >/dev/null 2>&1 || true
    if grep -q "controlled worker ok" "$controlled_queued_body"; then
        ok "controlled worker queued request completes after release"
    else
        ko "controlled worker queued request completes after release"
        echo "    queued body:"
        sed 's/^/      /' "$controlled_queued_body" 2>/dev/null || true
        print_logs
        return 1
    fi
    if grep -q "held by controlled worker" "$controlled_hold_body"; then
        ok "controlled worker busy request completes after queued request"
    else
        ko "controlled worker busy request completes after queued request"
        echo "    hold body:"
        sed 's/^/      /' "$controlled_hold_body" 2>/dev/null || true
        print_logs
        return 1
    fi
    wait_http_contains "http://127.0.0.1:${controlled_admin_port}/admin/runtime" '"queue_depth":0' \
        "controlled worker admin runtime clears queue depth after release"
    wait_http_contains "http://127.0.0.1:${controlled_admin_port}/admin/workers" '"served_requests":' \
        "controlled worker admin snapshot exposes served request count"
    wait_event_contains "${TMP_ROOT}/controlled-worker-queue.events.ndjson" "e2e-worker-queued-success" \
        "controlled worker queued success preserves trace id"

    rm -f "$controlled_release"
    curl -fsS --max-time 20 "${controlled_base_url}/hold?trace_id=e2e-worker-controlled-timeout-hold" >"$controlled_timeout_hold_body" 2>/dev/null &
    local controlled_timeout_hold_pid=$!
    wait_http_contains "http://127.0.0.1:${controlled_admin_port}/admin/workers" '"inflight_requests":1' \
        "controlled worker admin snapshot exposes busy worker before timeout"
    expect_http_status_contains_once "${controlled_base_url}/fast?trace_id=e2e-worker-queue-timeout" \
        "504" "" "controlled worker second request times out in queue" "3"
    wait_http_header_contains "${controlled_base_url}/fast?trace_id=e2e-worker-queue-timeout-header" \
        "x-vhttpd-error-class" "worker_queue_timeout" \
        "controlled worker queue timeout exposes error class"
    : >"$controlled_release"
    wait "$controlled_timeout_hold_pid" >/dev/null 2>&1 || true
    if grep -q "held by controlled worker" "$controlled_timeout_hold_body"; then
        ok "controlled worker busy request completes after queue timeout"
    else
        ko "controlled worker busy request completes after queue timeout"
        echo "    hold body:"
        sed 's/^/      /' "$controlled_timeout_hold_body" 2>/dev/null || true
        print_logs
        return 1
    fi
    wait_http_contains "http://127.0.0.1:${controlled_admin_port}/admin/runtime" '"timeouts_total":' \
        "controlled worker admin runtime records queue timeout"
    wait_event_contains "${TMP_ROOT}/controlled-worker-queue.events.ndjson" "e2e-worker-queue-timeout" \
        "controlled worker queue timeout preserves trace id"
    wait_event_contains "${TMP_ROOT}/controlled-worker-queue.events.ndjson" "worker_queue_timeout" \
        "controlled worker queue timeout is observable in event log"
    wait_event_contains "${TMP_ROOT}/controlled-worker-queue.events.ndjson" "e2e-worker-queue-full" \
        "controlled worker queue full preserves trace id"
    wait_event_contains "${TMP_ROOT}/controlled-worker-queue.events.ndjson" "worker_queue_full" \
        "controlled worker queue full is observable in event log"
}

require_binary
mkdir -p "$TMP_ROOT"

echo "=== vhttpd Config Acceptance Smoke Test ==="
test_v1_compat_smoke
test_v2_simple_site_smoke
test_v2_diagnostics_smoke
test_multisite_smoke
test_wordpress_v2_smoke
test_wordpress_installed_v2_smoke
test_protocol_conversion_smoke
test_relay_smoke
test_provider_runtime_smoke
test_db_runtime_smoke
test_cache_runtime_smoke
test_upload_event_pipeline_smoke
test_generic_event_pipeline_smoke
test_stream_dispatch_smoke
test_worker_queue_smoke

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
