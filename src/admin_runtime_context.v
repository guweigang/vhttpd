module main

import admin
import executor

// build_admin_context constructs an admin.RuntimeContext whose closures
// capture App, bridging the admin sub-module to the main program.
fn (mut app App) build_admin_context() admin.RuntimeContext {
	return admin.RuntimeContext{
		started_at_unix:                        fn [app] () i64 {
			return app.started_at_unix
		}
		http_requests_total:                    fn [app] () i64 {
			return app.http_stats.requests_total
		}
		http_errors_total:                      fn [app] () i64 {
			return app.http_stats.errors_total
		}
		http_timeouts_total:                    fn [app] () i64 {
			return app.http_stats.timeouts_total
		}
		http_streams_total:                     fn [app] () i64 {
			return app.http_stats.streams_total
		}
		http_admin_actions_total:               fn [app] () i64 {
			return app.http_stats.admin_actions_total
		}
		worker_queue_waits_total:               fn [app] () i64 {
			return app.executors.worker.stat_queue_waits_total
		}
		worker_queue_rejected_total:            fn [app] () i64 {
			return app.executors.worker.stat_queue_rejected_total
		}
		worker_queue_timeouts_total:            fn [app] () i64 {
			return app.executors.worker.stat_queue_timeouts_total
		}
		ws_hub_upstream_plans_total:            fn [app] () i64 {
			return app.transport.websocket.stat_upstream_plans_total
		}
		ws_hub_upstream_plan_errors_total:      fn [app] () i64 {
			return app.transport.websocket.stat_upstream_plan_errors_total
		}
		mcp_sessions_expired_total:             fn [app] () i64 {
			return app.protocols.mcp.stat_sessions_expired_total
		}
		mcp_sessions_evicted_total:             fn [app] () i64 {
			return app.protocols.mcp.stat_sessions_evicted_total
		}
		mcp_pending_dropped_total:              fn [app] () i64 {
			return app.protocols.mcp.stat_pending_dropped_total
		}
		mcp_sampling_capability_warnings_total: fn [app] () i64 {
			return app.protocols.mcp.stat_sampling_capability_warnings_total
		}
		mcp_sampling_capability_dropped_total:  fn [app] () i64 {
			return app.protocols.mcp.stat_sampling_capability_dropped_total
		}
		mcp_sampling_capability_errors_total:   fn [app] () i64 {
			return app.protocols.mcp.stat_sampling_capability_errors_total
		}
		feishu_runtime_totals:                  fn [mut app] () (i64, i64, i64, i64, i64, i64) {
			return app.providers.feishu.totals()
		}
		ws_hub_active_conns:                    fn [app] () int {
			app.transport.websocket.mu.@lock()
			defer { app.transport.websocket.mu.unlock() }
			return app.transport.websocket.conns.len
		}
		ws_hub_active_upstreams:                fn [app] () int {
			app.transport.websocket.upstream_mu.@lock()
			defer { app.transport.websocket.upstream_mu.unlock() }
			return app.transport.websocket.upstream_sessions.len
		}
		mcp_active_sessions:                    fn [mut app] (now i64) int {
			app.protocols.mcp.mu.@lock()
			defer { app.protocols.mcp.mu.unlock() }
			app.protocols.mcp.prune_sessions_locked(now)
			return app.protocols.mcp.sessions.len
		}
		worker_queue_depth:                     fn [app] () int {
			app.executors.worker.mu.@lock()
			defer { app.executors.worker.mu.unlock() }
			return app.executors.worker.worker_backend.queue_waiting_requests
		}
		worker_pool_size:                       fn [app] () i64 {
			return app.executors.worker.worker_backend.sockets.len
		}
		worker_backend_mode:                    fn [app] () string {
			return '${app.executors.worker.worker_backend_mode}'
		}
		worker_queue_capacity:                  fn [app] () int {
			return app.executors.worker.worker_backend.queue_capacity
		}
		worker_queue_timeout_ms:                fn [app] () int {
			return app.executors.worker.worker_backend.queue_timeout_ms
		}
		worker_stream_dispatch:                 fn [app] () bool {
			return app.executors.worker.stream_dispatch
		}
		ws_hub_dispatch_mode:                   fn [app] () bool {
			return app.transport.websocket.dispatch_mode
		}
		worker_lifecycle:                       fn [app] () string {
			return app.executors.worker.lifecycle
		}
		logic_executor_admin_details:           fn [app] () executor.LogicExecutorAdminDetails {
			return app.logic_executor_admin_details()
		}
		logic_executor_kind:                    fn [app] () string {
			return app.logic_executor_kind()
		}
		logic_executor_model:                   fn [app] () executor.LogicExecutorModel {
			return app.logic_executor_model()
		}
		logic_executor_provider:                fn [app] () string {
			return app.logic_executor_provider()
		}
		provider_runtime_capabilities:          fn [mut app] () map[string]bool {
			return app.provider_runtime_capabilities()
		}
		provider_runtime_gateway_count:         fn [mut app] () int {
			return app.provider_runtime_gateway_count()
		}
	}
}

fn (mut app App) admin_stats_snapshot() executor.AdminRuntimeStats {
	app.mu.@lock()
	defer { app.mu.unlock() }
	ctx := app.build_admin_context()
	return app.admin.stats_snapshot(ctx)
}

fn (mut app App) admin_runtime_snapshot() executor.AdminRuntimeSummary {
	ctx := app.build_admin_context()
	return app.admin.runtime_snapshot(ctx)
}
