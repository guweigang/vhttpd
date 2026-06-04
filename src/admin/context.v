module admin

import executor

// RuntimeContext is the interface admin sub-module needs from the
// App host. main.App implements this via duck typing, breaking
// the "admin → main" dependency.
//
// All methods are assumed to be called under App.mu lock.
pub interface RuntimeContext {
	// ── stats_snapshot fields ──
	started_at_unix() i64
	http_requests_total() i64
	http_errors_total() i64
	http_timeouts_total() i64
	http_streams_total() i64
	http_admin_actions_total() i64
	worker_queue_waits_total() i64
	worker_queue_rejected_total() i64
	worker_queue_timeouts_total() i64
	ws_hub_upstream_plans_total() i64
	ws_hub_upstream_plan_errors_total() i64
	mcp_sessions_expired_total() i64
	mcp_sessions_evicted_total() i64
	mcp_pending_dropped_total() i64
	mcp_sampling_capability_warnings_total() i64
	mcp_sampling_capability_dropped_total() i64
	mcp_sampling_capability_errors_total() i64

	// ── runtime_snapshot fields ──
	ws_hub_active_conns() int
	ws_hub_active_upstreams() int
	worker_pool_size() int
	worker_backend_mode() string
	worker_queue_capacity() int
	worker_queue_timeout_ms() int
	worker_stream_dispatch() bool
	ws_hub_dispatch_mode() bool
	worker_lifecycle() string
	logic_executor_admin_details() executor.LogicExecutorAdminDetails
	logic_executor_kind() string
	logic_executor_model() executor.LogicExecutorModel
	logic_executor_provider() string
}
