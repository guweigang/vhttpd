module main

import admin
import executor

// build_admin_context constructs an admin.RuntimeContext whose closures
// capture App, bridging the admin sub-module to the main program.
fn (mut app App) build_admin_context() admin.RuntimeContext {
	return admin.RuntimeContext{
		started_at_unix:                        fn [app] () i64 {
			return app.lifecycle.started_at_unix
		}
		http_requests_total:                    fn [app] () i64 {
			return app.control_plane.http_stats.requests_total
		}
		http_errors_total:                      fn [app] () i64 {
			return app.control_plane.http_stats.errors_total
		}
		http_timeouts_total:                    fn [app] () i64 {
			return app.control_plane.http_stats.timeouts_total
		}
		http_streams_total:                     fn [app] () i64 {
			return app.control_plane.http_stats.streams_total
		}
		http_admin_actions_total:               fn [app] () i64 {
			return app.control_plane.http_stats.admin_actions_total
		}
		worker_queue_waits_total:               fn [mut app] () i64 {
			return app.engines.metrics().queue_waits_total
		}
		worker_queue_rejected_total:            fn [mut app] () i64 {
			return app.engines.metrics().queue_rejected_total
		}
		worker_queue_timeouts_total:            fn [mut app] () i64 {
			return app.engines.metrics().queue_timeouts_total
		}
		ws_hub_upstream_plans_total:            fn [mut app] () i64 {
			total, _ := app.upstreams.totals()
			return total
		}
		ws_hub_upstream_plan_errors_total:      fn [mut app] () i64 {
			_, errors := app.upstreams.totals()
			return errors
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
		ws_hub_active_conns:                    fn [mut app] () int {
			return app.websocket.active_connections()
		}
		ws_hub_active_upstreams:                fn [mut app] () int {
			return app.upstreams.active_count()
		}
		mcp_active_sessions:                    fn [mut app] (now i64) int {
			app.protocols.mcp.mu.@lock()
			defer { app.protocols.mcp.mu.unlock() }
			app.protocols.mcp.prune_sessions_locked(now)
			return app.protocols.mcp.sessions.len
		}
		worker_queue_depth:                     fn [mut app] () int {
			return app.engines.metrics().queue_depth
		}
		worker_pool_size:                       fn [mut app] () i64 {
			return app.engines.metrics().pool_size
		}
		worker_backend_mode:                    fn [mut app] () string {
			return app.engines.metrics().backend_mode
		}
		worker_queue_capacity:                  fn [mut app] () int {
			return app.engines.metrics().queue_capacity
		}
		worker_queue_timeout_ms:                fn [mut app] () int {
			return app.engines.metrics().queue_timeout_ms
		}
		worker_stream_dispatch:                 fn [mut app] () bool {
			return app.engines.metrics().stream_dispatch
		}
		ws_hub_dispatch_mode:                   fn [app] () bool {
			return app.websocket.dispatch_enabled()
		}
		worker_lifecycle:                       fn [mut app] () string {
			return app.engines.metrics().lifecycle
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
		pipeline_runtime_snapshot:              fn [app] () executor.AdminPipelineRuntimeSummary {
			return app.admin_pipeline_runtime_snapshot()
		}
		listener_runtime_snapshots:             fn () []executor.AdminListenerRuntimeSummary {
			return active_runtime_listener_summaries()
		}
		provider_runtime_capabilities:          fn [mut app] () map[string]bool {
			return app.provider_runtime_capabilities()
		}
		provider_runtime_gateway_count:         fn [mut app] () int {
			return app.provider_runtime_gateway_count()
		}
		relay_runtime_snapshot:                 fn [mut app] () executor.AdminRelayRuntimeSummary {
			return app.admin_relay_runtime_snapshot()
		}
	}
}

fn (app App) admin_pipeline_runtime_snapshot() executor.AdminPipelineRuntimeSummary {
	routes := app.pipelines.http.rules.map(executor.AdminPipelineRouteSummary{
		pipeline_id: it.pipeline_id
		group:       it.pipeline_group
		ingress:     it.ingress_id
		egress:      it.egress_ref
		executor:    it.dispatch_executor()
		methods:     it.match_method.clone()
		paths:       it.match_path.clone()
	})
	return executor.AdminPipelineRuntimeSummary{
		listener_id: app.pipelines.http.listener_id
		route_count: routes.len
		routes:      routes
	}
}

fn (mut app App) admin_relay_runtime_snapshot() executor.AdminRelayRuntimeSummary {
	snapshot := app.relay.snapshot()
	return executor.AdminRelayRuntimeSummary{
		descriptor_count: snapshot.descriptor_count
		agent_count:      snapshot.agent_count
		channel_count:    snapshot.channel_count
		open_channels:    snapshot.open_channels
		carrier_count:    snapshot.carrier_count
		session_count:    snapshot.session_count
		pending_frames:   snapshot.pending_frames
		returned_frames:  snapshot.returned_frames
		agents:           snapshot.agents.map(executor.AdminRelayAgentSummary{
			node_id:            it.node_id
			relay_id:           it.relay_id
			state:              it.state
			attempt:            it.attempt
			next_attempt_at_ms: it.next_attempt_at_ms
			last_error:         it.last_error
		})
		carriers:         snapshot.carriers.map(executor.AdminRelayCarrierSummary{
			relay_id:   it.relay_id
			carrier_id: it.carrier_id
		})
		channels:         snapshot.channels.map(executor.AdminRelayChannelSummary{
			id:           it.id
			node_id:      it.node_id
			route:        it.route
			trace_id:     it.trace_id
			open:         it.open
			buffered_len: it.buffered_len
			returned_len: it.returned_len
		})
		sessions:         snapshot.sessions.map(executor.AdminRelaySessionSummary{
			id:             it.id
			endpoint_count: it.endpoint_count
			link_count:     it.link_count
			pending_frames: it.pending_frames
		})
	}
}

fn (mut app App) admin_stats_snapshot() executor.AdminRuntimeStats {
	ctx := app.build_admin_context()
	return app.control_plane.stats_snapshot(ctx)
}

fn (mut app App) admin_runtime_snapshot() executor.AdminRuntimeSummary {
	ctx := app.build_admin_context()
	return app.control_plane.runtime_snapshot(ctx)
}
