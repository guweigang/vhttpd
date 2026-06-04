module admin

import executor

// RuntimeContext carries closures that bridge admin sub-module
// to the main App. Each closure captures what it needs from App,
// so admin/ never imports main.
//
// Build it once per call in the thin wrapper, then pass it in.
pub struct RuntimeContext {
pub:
	// ── Stats fields ──
	started_at_unix                          fn () i64
	http_requests_total                      fn () i64
	http_errors_total                        fn () i64
	http_timeouts_total                      fn () i64
	http_streams_total                       fn () i64
	http_admin_actions_total                 fn () i64
	worker_queue_waits_total                 fn () i64
	worker_queue_rejected_total              fn () i64
	worker_queue_timeouts_total              fn () i64
	ws_hub_upstream_plans_total              fn () i64
	ws_hub_upstream_plan_errors_total        fn () i64
	mcp_sessions_expired_total               fn () i64
	mcp_sessions_evicted_total               fn () i64
	mcp_pending_dropped_total                fn () i64
	mcp_sampling_capability_warnings_total   fn () i64
	mcp_sampling_capability_dropped_total    fn () i64
	mcp_sampling_capability_errors_total     fn () i64
	feishu_runtime_totals                    fn () (i64, i64, i64, i64, i64, i64)

	// ── Runtime snapshot fields ──
	ws_hub_active_conns              fn () int
	ws_hub_active_upstreams          fn () int
	mcp_active_sessions              fn (i64) int
	worker_queue_depth               fn () int
	worker_pool_size                 fn () int
	worker_backend_mode              fn () string
	worker_queue_capacity            fn () int
	worker_queue_timeout_ms          fn () int
	worker_stream_dispatch           fn () bool
	ws_hub_dispatch_mode             fn () bool
	worker_lifecycle                 fn () string
	logic_executor_admin_details     fn () executor.LogicExecutorAdminDetails
	logic_executor_kind              fn () string
	logic_executor_model             fn () executor.LogicExecutorModel
	logic_executor_provider          fn () string
	provider_runtime_capabilities    fn () map[string]bool
	provider_runtime_gateway_count   fn () int
}
