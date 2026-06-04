module admin

import executor
import time

// ── Runtime snapshot builders ──
// These methods receive a RuntimeContext (interface implemented by main.App)
// instead of depending on App directly, enabling admin/ to be a standalone
// sub-module.

// stats_snapshot returns a point-in-time snapshot of runtime stats.
// Caller must hold RuntimeContext's lock.
pub fn (mut s AdminState) stats_snapshot(ctx RuntimeContext, feishu_connect_attempts i64, feishu_connect_successes i64, feishu_received_frames i64, feishu_acked_events i64, feishu_messages_sent i64, feishu_send_errors i64) executor.AdminRuntimeStats {
	now := time.now().unix()
	started := if ctx.started_at_unix() > 0 { ctx.started_at_unix() } else { now }
	uptime := if now > started { now - started } else { 0 }
	return executor.AdminRuntimeStats{
		started_at_unix: started
		uptime_seconds:  uptime
		http: executor.AdminHttpStats{
			requests_total: ctx.http_requests_total()
			errors_total:   ctx.http_errors_total()
			timeouts_total: ctx.http_timeouts_total()
			streams_total:  ctx.http_streams_total()
		}
		worker: executor.AdminWorkerQueueStats{
			waits_total:    ctx.worker_queue_waits_total()
			rejected_total: ctx.worker_queue_rejected_total()
			timeouts_total: ctx.worker_queue_timeouts_total()
		}
		upstream: executor.AdminUpstreamStats{
			plans_total:       ctx.ws_hub_upstream_plans_total()
			plan_errors_total: ctx.ws_hub_upstream_plan_errors_total()
		}
		mcp: executor.AdminMcpStats{
			sessions_expired_total:             ctx.mcp_sessions_expired_total()
			sessions_evicted_total:             ctx.mcp_sessions_evicted_total()
			pending_dropped_total:              ctx.mcp_pending_dropped_total()
			sampling_capability_warnings_total: ctx.mcp_sampling_capability_warnings_total()
			sampling_capability_dropped_total:  ctx.mcp_sampling_capability_dropped_total()
			sampling_capability_errors_total:   ctx.mcp_sampling_capability_errors_total()
		}
		feishu: executor.AdminFeishuStats{
			connect_attempts:  feishu_connect_attempts
			connect_successes: feishu_connect_successes
			received_frames:   feishu_received_frames
			acked_events:      feishu_acked_events
			messages_sent:     feishu_messages_sent
			send_errors:       feishu_send_errors
		}
		admin_actions_total: ctx.http_admin_actions_total()
	}
}

// runtime_snapshot returns an extended snapshot including active
// connection counts and pool details.
// Caller must hold RuntimeContext's lock.
pub fn (mut s AdminState) runtime_snapshot(ctx RuntimeContext, active_mcp_sessions int, worker_queue_depth int, provider_capabilities map[string]bool, provider_gateway_count int, feishu_connect_attempts i64, feishu_connect_successes i64, feishu_received_frames i64, feishu_acked_events i64, feishu_messages_sent i64, feishu_send_errors i64) executor.AdminRuntimeSummary {
	stats := s.stats_snapshot(ctx, feishu_connect_attempts, feishu_connect_successes, feishu_received_frames, feishu_acked_events, feishu_messages_sent, feishu_send_errors)
	active_websockets := ctx.ws_hub_active_conns()
	active_upstreams := ctx.ws_hub_active_upstreams()
	mut capabilities := map[string]bool{}
	capabilities['http'] = true
	capabilities['stream'] = true
	capabilities['stream_direct'] = true
	capabilities['stream_dispatch'] = ctx.worker_stream_dispatch()
	capabilities['stream_upstream_plan'] = true
	capabilities['websocket'] = true
	capabilities['websocket_dispatch'] = ctx.ws_hub_dispatch_mode()
	capabilities['mcp'] = true
	capabilities['websocket_upstream'] = true
	for key, value in provider_capabilities {
		capabilities[key] = value
	}
	logic_details := ctx.logic_executor_admin_details()
	return executor.AdminRuntimeSummary{
		started_at_unix: stats.started_at_unix
		uptime_seconds:  stats.uptime_seconds
		worker_pool: executor.AdminWorkerPoolSummary{
			pool_size:        ctx.worker_pool_size()
			backend_mode:     ctx.worker_backend_mode()
			queue_capacity:   ctx.worker_queue_capacity()
			queue_timeout_ms: ctx.worker_queue_timeout_ms()
			queue_depth:      worker_queue_depth
		}
		logic_executor: executor.AdminLogicExecutorSummary{
			kind:      ctx.logic_executor_kind()
			lifecycle: ctx.worker_lifecycle()
			model:     '${ctx.logic_executor_model()}'
			provider:  ctx.logic_executor_provider()
			details:   logic_details
		}
		capabilities: capabilities
		active: executor.AdminActiveCounts{
			websockets:   active_websockets
			upstreams:    active_upstreams
			mcp_sessions: active_mcp_sessions
			gateways:     provider_gateway_count
		}
		stats: stats
	}
}
