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
	started_at_unix                          fn () i64                     = unsafe { nil }
	http_requests_total                      fn () i64                     = unsafe { nil }
	http_errors_total                        fn () i64                     = unsafe { nil }
	http_timeouts_total                      fn () i64                     = unsafe { nil }
	http_streams_total                       fn () i64                     = unsafe { nil }
	http_admin_actions_total                 fn () i64                     = unsafe { nil }
	worker_queue_waits_total                 fn () i64                     = unsafe { nil }
	worker_queue_rejected_total              fn () i64                     = unsafe { nil }
	worker_queue_timeouts_total              fn () i64                     = unsafe { nil }
	ws_hub_upstream_plans_total              fn () i64                     = unsafe { nil }
	ws_hub_upstream_plan_errors_total        fn () i64                     = unsafe { nil }
	mcp_sessions_expired_total               fn () i64                     = unsafe { nil }
	mcp_sessions_evicted_total               fn () i64                     = unsafe { nil }
	mcp_pending_dropped_total                fn () i64                     = unsafe { nil }
	mcp_sampling_capability_warnings_total   fn () i64                     = unsafe { nil }
	mcp_sampling_capability_dropped_total    fn () i64                     = unsafe { nil }
	mcp_sampling_capability_errors_total     fn () i64                     = unsafe { nil }
	feishu_runtime_totals                    fn () (i64, i64, i64, i64, i64, i64) = unsafe { nil }

	// ── Runtime snapshot fields ──
	ws_hub_active_conns              fn () int                                    = unsafe { nil }
	ws_hub_active_upstreams          fn () int                                    = unsafe { nil }
	mcp_active_sessions              fn (i64) int                                 = unsafe { nil }
	worker_queue_depth               fn () int                                    = unsafe { nil }
	worker_pool_size                 fn () int                                    = unsafe { nil }
	worker_backend_mode              fn () string                                 = unsafe { nil }
	worker_queue_capacity            fn () int                                    = unsafe { nil }
	worker_queue_timeout_ms          fn () int                                    = unsafe { nil }
	worker_stream_dispatch           fn () bool                                   = unsafe { nil }
	ws_hub_dispatch_mode             fn () bool                                   = unsafe { nil }
	worker_lifecycle                 fn () string                                 = unsafe { nil }
	logic_executor_admin_details     fn () executor.LogicExecutorAdminDetails     = unsafe { nil }
	logic_executor_kind              fn () string                                 = unsafe { nil }
	logic_executor_model             fn () executor.LogicExecutorModel            = unsafe { nil }
	logic_executor_provider          fn () string                                 = unsafe { nil }
	provider_runtime_capabilities    fn () map[string]bool                        = unsafe { nil }
	provider_runtime_gateway_count   fn () int                                    = unsafe { nil }
}
