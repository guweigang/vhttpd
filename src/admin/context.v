module admin

import executor

// RuntimeContext requires explicitly injected reads from the owning subsystems.
//
// Build it once per call in the thin wrapper, then pass it in.
pub struct RuntimeContext {
pub:
	// ── Stats fields ──
	started_at_unix                        fn () i64 @[required]
	http_requests_total                    fn () i64 @[required]
	http_errors_total                      fn () i64 @[required]
	http_timeouts_total                    fn () i64 @[required]
	http_streams_total                     fn () i64 @[required]
	http_admin_actions_total               fn () i64 @[required]
	worker_queue_waits_total               fn () i64 @[required]
	worker_queue_rejected_total            fn () i64 @[required]
	worker_queue_timeouts_total            fn () i64 @[required]
	ws_hub_upstream_plans_total            fn () i64 @[required]
	ws_hub_upstream_plan_errors_total      fn () i64 @[required]
	mcp_sessions_expired_total             fn () i64 @[required]
	mcp_sessions_evicted_total             fn () i64 @[required]
	mcp_pending_dropped_total              fn () i64 @[required]
	mcp_sampling_capability_warnings_total fn () i64 @[required]
	mcp_sampling_capability_dropped_total  fn () i64 @[required]
	mcp_sampling_capability_errors_total   fn () i64 @[required]
	feishu_runtime_totals                  fn () (i64, i64, i64, i64, i64, i64) @[required]

	// ── Runtime snapshot fields ──
	ws_hub_active_conns            fn () int    @[required]
	ws_hub_active_upstreams        fn () int    @[required]
	mcp_active_sessions            fn (i64) int @[required]
	worker_queue_depth             fn () int    @[required]
	worker_pool_size               fn () int    @[required]
	worker_backend_mode            fn () string @[required]
	worker_queue_capacity          fn () int    @[required]
	worker_queue_timeout_ms        fn () int    @[required]
	worker_stream_dispatch         fn () bool   @[required]
	ws_hub_dispatch_mode           fn () bool   @[required]
	worker_lifecycle               fn () string @[required]
	logic_executor_admin_details   fn () executor.LogicExecutorAdminDetails @[required]
	logic_executor_kind            fn () string                                 @[required]
	logic_executor_model           fn () executor.LogicExecutorModel            @[required]
	logic_executor_provider        fn () string                                 @[required]
	pipeline_runtime_snapshot      fn () executor.AdminPipelineRuntimeSummary   @[required]
	listener_runtime_snapshots     fn () []executor.AdminListenerRuntimeSummary @[required]
	provider_runtime_capabilities  fn () map[string]bool                        @[required]
	provider_runtime_gateway_count fn () int @[required]
	relay_runtime_snapshot         fn () executor.AdminRelayRuntimeSummary @[required]
}
