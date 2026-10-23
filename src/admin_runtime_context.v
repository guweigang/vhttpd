module main

import admin
import executor
import relay

// Publication-sensitive fields are values from one view; live counters retain
// their actual subsystem owners and never take ownership of native resources.
fn (mut app App) build_admin_context() admin.RuntimeContext {
	mut lifecycle := &app.lifecycle
	mut control := &app.control_plane
	mut upstreams := &app.upstreams
	mut mcp := &app.protocols.mcp
	mut feishu := &app.providers.feishu
	mut websocket := &app.websocket
	mut relay_runtime := &app.relay
	app.mu.@lock()
	engine_metrics := app.engines.metrics()
	engine := executor.logic_executor_http_port(app.engines.primary.logic_executor)
	pipeline := app.pipelines.admin_snapshot()
	provider_ctx := app.build_provider_runtime_dispatch_context_unlocked()
	app.mu.unlock()
	details := engine.admin_details()
	kind := engine.kind()
	model := engine.model()
	provider_name := engine.provider()
	return admin.RuntimeContext{
		started_at_unix:                        fn [mut lifecycle] () i64 {
			return lifecycle.started_at_unix
		}
		http_requests_total:                    fn [mut control] () i64 {
			return control.http_stats.requests_total
		}
		http_errors_total:                      fn [mut control] () i64 {
			return control.http_stats.errors_total
		}
		http_timeouts_total:                    fn [mut control] () i64 {
			return control.http_stats.timeouts_total
		}
		http_streams_total:                     fn [mut control] () i64 {
			return control.http_stats.streams_total
		}
		http_admin_actions_total:               fn [mut control] () i64 {
			return control.http_stats.admin_actions_total
		}
		worker_queue_waits_total:               fn [engine_metrics] () i64 {
			return engine_metrics.queue_waits_total
		}
		worker_queue_rejected_total:            fn [engine_metrics] () i64 {
			return engine_metrics.queue_rejected_total
		}
		worker_queue_timeouts_total:            fn [engine_metrics] () i64 {
			return engine_metrics.queue_timeouts_total
		}
		ws_hub_upstream_plans_total:            fn [mut upstreams] () i64 {
			total, _ := upstreams.totals()
			return total
		}
		ws_hub_upstream_plan_errors_total:      fn [mut upstreams] () i64 {
			_, errors := upstreams.totals()
			return errors
		}
		mcp_sessions_expired_total:             fn [mut mcp] () i64 {
			mcp.mu.@lock()
			defer { mcp.mu.unlock() }
			return mcp.stat_sessions_expired_total
		}
		mcp_sessions_evicted_total:             fn [mut mcp] () i64 {
			mcp.mu.@lock()
			defer { mcp.mu.unlock() }
			return mcp.stat_sessions_evicted_total
		}
		mcp_pending_dropped_total:              fn [mut mcp] () i64 {
			mcp.mu.@lock()
			defer { mcp.mu.unlock() }
			return mcp.stat_pending_dropped_total
		}
		mcp_sampling_capability_warnings_total: fn [mut mcp] () i64 {
			mcp.mu.@lock()
			defer { mcp.mu.unlock() }
			return mcp.stat_sampling_capability_warnings_total
		}
		mcp_sampling_capability_dropped_total:  fn [mut mcp] () i64 {
			mcp.mu.@lock()
			defer { mcp.mu.unlock() }
			return mcp.stat_sampling_capability_dropped_total
		}
		mcp_sampling_capability_errors_total:   fn [mut mcp] () i64 {
			mcp.mu.@lock()
			defer { mcp.mu.unlock() }
			return mcp.stat_sampling_capability_errors_total
		}
		feishu_runtime_totals:                  fn [mut feishu] () (i64, i64, i64, i64, i64, i64) {
			return feishu.totals()
		}
		ws_hub_active_conns:                    fn [mut websocket] () int {
			return websocket.active_connections()
		}
		ws_hub_active_upstreams:                fn [mut upstreams] () int {
			return upstreams.active_count()
		}
		mcp_active_sessions:                    fn [mut mcp] (now i64) int {
			mcp.mu.@lock()
			defer { mcp.mu.unlock() }
			mcp.prune_sessions_locked(now)
			return mcp.sessions.len
		}
		worker_queue_depth:                     fn [engine_metrics] () int {
			return engine_metrics.queue_depth
		}
		worker_pool_size:                       fn [engine_metrics] () i64 {
			return engine_metrics.pool_size
		}
		worker_backend_mode:                    fn [engine_metrics] () string {
			return engine_metrics.backend_mode
		}
		worker_queue_capacity:                  fn [engine_metrics] () int {
			return engine_metrics.queue_capacity
		}
		worker_queue_timeout_ms:                fn [engine_metrics] () int {
			return engine_metrics.queue_timeout_ms
		}
		worker_stream_dispatch:                 fn [engine_metrics] () bool {
			return engine_metrics.stream_dispatch
		}
		ws_hub_dispatch_mode:                   fn [mut websocket] () bool {
			return websocket.dispatch_enabled()
		}
		worker_lifecycle:                       fn [engine_metrics] () string {
			return engine_metrics.lifecycle
		}
		logic_executor_admin_details:           fn [details] () executor.LogicExecutorAdminDetails {
			return details
		}
		logic_executor_kind:                    fn [kind] () string { return kind }
		logic_executor_model:                   fn [model] () executor.LogicExecutorModel {
			return model
		}
		logic_executor_provider:                fn [provider_name] () string {
			return provider_name
		}
		pipeline_runtime_snapshot:              fn [pipeline] () executor.AdminPipelineRuntimeSummary {
			return pipeline
		}
		listener_runtime_snapshots:             fn () []executor.AdminListenerRuntimeSummary {
			return active_runtime_listener_summaries()
		}
		provider_runtime_capabilities:          fn [provider_ctx] () map[string]bool {
			return provider_ctx.capabilities()
		}
		provider_runtime_gateway_count:         fn [provider_ctx] () int {
			return provider_ctx.gateway_count()
		}
		relay_runtime_snapshot:                 fn [mut relay_runtime] () executor.AdminRelayRuntimeSummary {
			return relay_admin_snapshot(mut relay_runtime)
		}
	}
}

fn (runtime PipelineRuntime) admin_snapshot() executor.AdminPipelineRuntimeSummary {
	routes := runtime.http.rules.map(executor.AdminPipelineRouteSummary{
		pipeline_id: it.pipeline_id
		group:       it.pipeline_group
		ingress:     it.ingress_id
		egress:      it.egress_ref
		executor:    it.dispatch_executor()
		methods:     it.match_method.clone()
		paths:       it.match_path.clone()
	})
	return executor.AdminPipelineRuntimeSummary{
		listener_id: runtime.http.listener_id
		route_count: routes.len
		routes:      routes
	}
}

fn relay_admin_snapshot(mut runtime relay.Runtime) executor.AdminRelayRuntimeSummary {
	snapshot := runtime.snapshot()
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

fn (app &App) admin_pipeline_runtime_snapshot() executor.AdminPipelineRuntimeSummary {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.pipelines.admin_snapshot()
}

fn (mut app App) admin_relay_runtime_snapshot() executor.AdminRelayRuntimeSummary {
	return relay_admin_snapshot(mut app.relay)
}
