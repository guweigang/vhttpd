#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -e src/executor_bridge.v ]]; then
    echo "Executor facade must not restore the unsafe executor_bridge.v wrapper." >&2
    exit 1
fi

# Guard typed application references across the executor and provider adapters.
pattern='AppFacadeWrapper|voidptr[[:space:]]*\([[:space:]]*&app[[:space:]]*\)|unsafe[[:space:]]*\{[[:space:]]*&App[[:space:]]*\('
scan_facade() {
    if command -v rg >/dev/null 2>&1; then
        rg -n -g '*.v' "$pattern" src
    else
        grep -REn --include='*.v' "$pattern" src
    fi
}
if scan_facade; then
    echo "Executor facade must retain typed references, without raw App pointer casts." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

worker_pattern='(^import[[:space:]]+main([[:space:]]|$)|(^|[^[:alnum:]_])(App|EngineRuntime)([^[:alnum:]_]|$))'
scan_worker() {
    if command -v rg >/dev/null 2>&1; then
        rg -n -g '*.v' -g '!*_test.v' "$worker_pattern" src/worker
    else
        grep -REn --include='*.v' --exclude='*_test.v' "$worker_pattern" src/worker
    fi
}
if scan_worker; then
    echo "Worker core must not depend on the application or engine registry." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

scan_worker_executor_capabilities() {
    local capability_pattern='(^|[^[:alnum:]_])AppFacade([^[:alnum:]_]|$)'
    if command -v rg >/dev/null 2>&1; then
        rg -n "$capability_pattern" src/executor/app_facade_ports.v src/executor/worker_dispatch_core.v
    else
        grep -En "$capability_pattern" src/executor/app_facade_ports.v src/executor/worker_dispatch_core.v
    fi
}
if scan_worker_executor_capabilities; then
    echo "Worker executor ports and dispatch core must use narrow capability interfaces." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

scan_embedded_capabilities() {
    local embedded_pattern='(^|[^[:alnum:]_])AppFacade([^[:alnum:]_]|$)'
    if command -v rg >/dev/null 2>&1; then
        rg -n -g 'inproc*.v' -g '!inproc_vjsx_facade_adapter.v' "$embedded_pattern" src/executor
    else
        grep -REn --include='inproc*.v' --exclude='inproc_vjsx_facade_adapter.v' "$embedded_pattern" src/executor
    fi
}
if scan_embedded_capabilities; then
    echo "Embedded executor internals must use EmbeddedHost; AppFacade belongs at the adapter boundary." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

scan_embedded_nil_hosts() {
    local nil_pattern='EmbeddedHost[[:space:]]*\([[:space:]]*unsafe|app_ref[[:space:]]+EmbeddedHost[[:space:]]*='
    if command -v rg >/dev/null 2>&1; then
        rg -n -g 'inproc*.v' "$nil_pattern" src/executor
    else
        grep -REn --include='inproc*.v' "$nil_pattern" src/executor
    fi
}
if scan_embedded_nil_hosts; then
    echo "Embedded retained hosts must be optional, without unsafe interface placeholders." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

scan_command_provider_hosts() {
    local host_pattern='(^|[^[:alnum:]_])App([^[:alnum:]_]|$)'
    if command -v rg >/dev/null 2>&1; then
        rg -n "$host_pattern" src/command_handlers.v src/command_host.v src/provider_websocket_host.v src/feishu_card_bridge_client_runtime.v
    else
        grep -En "$host_pattern" src/command_handlers.v src/command_host.v src/provider_websocket_host.v src/feishu_card_bridge_client_runtime.v
    fi
}
if scan_command_provider_hosts; then
    echo "Command handlers and bridge client internals must use explicit capability hosts." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

scan_nil_runtime_callbacks() {
    local callback_pattern='fn.*unsafe[[:space:]]*\{[[:space:]]*nil[[:space:]]*\}'
    local context_files=(src/command/context.v src/provider/context.v src/provider/runtime_dispatch.v src/provider_instance_runtime.v src/stream_runtime.v src/admin/context.v src/ws/hub_runtime.v src/ws/upstream_runtime.v src/ws/relay_agent.v src/ws/relay_carrier.v src/websocket_runtime.v src/upstream_runtime.v src/upstream/types.v src/dbx/runtime.v src/api/openai/path.v src/executor/lifecycle.v src/executor/registry.v src/ws/relay_session.v src/dispatch_event_services.v src/websocket_relay_runtime.v)
    if command -v rg >/dev/null 2>&1; then
        rg -n "$callback_pattern" "${context_files[@]}"
    else
        grep -En "$callback_pattern" "${context_files[@]}"
    fi
}
if scan_nil_runtime_callbacks; then
    echo "Command/provider/stream runtime callbacks must be injected explicitly, without nil defaults." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

scan_implicit_runtime_callbacks() {
    local field_pattern='^[[:space:]]*[[:alnum:]_]+[[:space:]]+fn[[:space:]]*\('
    local context_files=(src/command/context.v src/provider/context.v src/provider/runtime_dispatch.v src/provider_instance_runtime.v src/stream_runtime.v src/admin/context.v src/ws/hub_runtime.v src/ws/upstream_runtime.v src/ws/relay_agent.v src/ws/relay_carrier.v src/websocket_runtime.v src/upstream_runtime.v src/upstream/types.v src/dbx/runtime.v src/api/openai/path.v src/executor/lifecycle.v src/executor/registry.v src/ws/relay_session.v src/dispatch_event_services.v src/websocket_relay_runtime.v)
    if command -v rg >/dev/null 2>&1; then
        rg -n "$field_pattern" "${context_files[@]}" | rg -v '@\[required\]|:[[:space:]]*pub[[:space:]]+fn[[:space:]]*\('
    else
        grep -En "$field_pattern" "${context_files[@]}" | grep -Ev '@\[required\]|:[[:space:]]*pub[[:space:]]+fn[[:space:]]*\('
    fi
}
if scan_implicit_runtime_callbacks; then
    echo "Command/provider/stream callback fields must require constructor injection." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

scan_retained_adapter_context() {
    local adapter_fields
    adapter_fields="$(awk '/^pub struct ProviderRuntimeAdapter /,/^}/' src/provider_spec.v)"
    if command -v rg >/dev/null 2>&1; then
        printf '%s\n' "$adapter_fields" | rg -n 'provider[.]RuntimeContext'
    else
        printf '%s\n' "$adapter_fields" | grep -En 'provider[.]RuntimeContext'
    fi
}
if scan_retained_adapter_context; then
    echo "ProviderSpec owns the lifecycle context; ProviderRuntimeAdapter must only forward it." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

if rg -n 'provider_register_and_start|[.]register_provider\(' src/provider_bootstrap.v; then
    echo "Provider bootstrap must register the complete spec without rebuilding its context." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

if rg -n '(^|[^[:alnum:]_])App([^[:alnum:]_]|$)' src/stream_runtime.v src/stream_dispatch_runtime.v src/stream_direct_runtime.v; then
    echo "Stream execution must use its injected context; App belongs in app_stream_runtime.v." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then
        exit "$status"
    fi
fi

if rg -n 'fn.*unsafe[[:space:]]*\{[[:space:]]*nil[[:space:]]*\}' src --glob '*.v'; then
    echo "Runtime callback fields must use explicit injection, never nil defaults." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then exit "$status"; fi
fi
if rg -n '(^|[^[:alnum:]_])App([^[:alnum:]_]|$)' src/websocket_runtime.v src/upstream_runtime.v src/upstream_runtime_registry.v src/websocket_relay_runtime.v src/dispatch_event_services.v; then
    echo "Runtime context ownership belongs to subsystems; App adapters must remain separate." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then exit "$status"; fi
fi

if rg -n '&App[[:space:]]*=[[:space:]]*unsafe|app:[[:space:]]*unsafe[[:space:]]*\{[[:space:]]*&app' src/admin_server.v src/multi_server_runtime_orchestrator.v src/relay_pipeline_runtime.v src/http_dispatch_exchange_runtime.v; then
    echo "App bindings must be required; event services must not retain App." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then exit "$status"; fi
fi
if rg -n 'fn[[:space:]]*\[[^]]*app' src/admin_runtime_context.v; then
    echo "Admin reads must capture subsystem owners instead of App." >&2
    exit 1
else
    status=$?
    if [[ "$status" -ne 1 ]]; then exit "$status"; fi
fi

echo "Executor, worker, embedded and runtime context ownership checks passed."

# Resource absence must use typed options; callback user_ptr casts are C boundaries.
resource_handle_files=(
  src/main.v src/http_observation_stages.v src/executor/http_request_timing.v
  src/codex/types.v src/upstream/provider/codex/types.v
  src/feishu/types.v src/upstream/provider/feishu/types.v
  src/feishu_card_bridge_runtime.v src/cachex/runtime.v src/executor/types.v
  src/executor/inproc_vjsx_lane_host.v src/executor/inproc_vjsx_host_lifecycle.v
  src/api/mcp/protocol/types.v src/api/mcp/protocol/state.v
  src/ws/types.v src/ws/hub_runtime.v src/ws/runtime.v
  src/upstream/transport/worker_pool.v src/worker/lifecycle.v
  src/openai_stream_proxy_runtime.v src/upstream/ndjson_streamer.v
)
if rg -n 'unsafe[[:space:]]*\{[[:space:]]*nil[[:space:]]*\}' "${resource_handle_files[@]}"; then
  echo 'Resource handles must use explicit options or required references.' >&2
  exit 1
fi

# Embedded executors and queued tasks are constructed with real shared state.
if rg -n 'unsafe[[:space:]]*\{[[:space:]]*nil[[:space:]]*\}|isnil\(e\.state\)' src/executor -g '*.v'; then
  echo 'Embedded executor state and task slots must be required references.' >&2
  exit 1
fi
if rg -n 'EmbeddedHost[[:space:]]*=[[:space:]]*NoOpAppFacade' src/executor/inproc_vjsx_lane_types.v src/executor/inproc_vjsx_websocket_types.v; then
  echo 'Queued tasks must receive their host explicitly.' >&2
  exit 1
fi

# Managed worker OS lifetime belongs to process_runtime, including signal cleanup.
if rg -n 'g_managed_worker_processes|get_child_pids|os\.new_process|signal_pgkill|proc\.(wait|close|is_alive)\(' src/upstream/transport/worker_pool.v src/worker/lifecycle.v; then
  echo 'Worker processes must use the managed process owner for launch/probe/retirement.' >&2
  exit 1
fi
if rg -n 'get_child_pids|C\.kill' src/server.v; then
  echo 'Signal shutdown must drain the process owner instead of stale PID snapshots.' >&2
  exit 1
fi

# Transactions retain a single native-handle owner and issue exclusive leases.
if rg -n 'tx_sessions[[:space:]]+map\[string\]SessionHandle|transaction_session\(.*\)[[:space:]]+\?SessionHandle|db_runtime_acquire_conn\(.*\)[[:space:]]+!dbx\.SessionHandle' src/dbx/runtime.v src/db_runtime_pool.v; then
  echo 'DB transaction requests must borrow an exclusive lease instead of copying native handles.' >&2
  exit 1
fi

# Pool construction, refill and native-handle ownership belong to dbx.PoolOwner.
if rg -n 'dbx\.PoolHandle\.open|\.pool_handle\(|\.detach_pool\(' src/db_runtime_pool.v; then
  echo 'DB pool adapters must use the pool owner and originating lease.' >&2
  exit 1
fi

# MCP stream tasks must retain their connection identity through teardown.
if rg -n 'bind_conn|unbind_conn|flush_session\(' src/mcp_session_stream_runtime.v; then
  echo 'MCP SSE handlers must transfer connections to the stream owner and use its lifecycle.' >&2
  exit 1
fi

# Delayed lane pumps retain a session owner and participate in executor shutdown.
if rg -n 'schedule_lane_wakeup|cancel_lane_wakeup|VjsxLaneWakeup\{\}' src/executor/inproc_vjsx_host_lifecycle.v src/executor/inproc_vjsx_lane_wakeup_runtime.v; then
  echo 'Lane wakeups must retain their originating session owner and explicit lookup.' >&2
  exit 1
fi

# Socket interruption descriptors must not leak into executed worker children.
if rg -n 'C\.dup\(' src/connection_runtime/owner.c.v; then
  echo 'WebSocket interrupt descriptors must be duplicated atomically with CLOEXEC.' >&2
  exit 1
fi

# Codex delayed error delivery belongs to owned jobs, not copied config/state.
if rg -n 'err_bursts|err_pending_flushes' src/codex/types.v src/codex/state.v src/codex/runtime.v; then
  echo 'Codex error bursts must live in their task owner instead of runtime snapshots.' >&2
  exit 1
fi
if rg -n 'time\.sleep\(' src/codex_turn_runtime.v; then
  echo 'Codex error flush delays must use the registered job cancellation boundary.' >&2
  exit 1
fi
