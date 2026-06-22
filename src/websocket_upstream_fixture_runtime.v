module main

import time
import upstream

fn (mut app App) fixture_websocket_emit(req upstream.UpstreamFixtureEmitRequest) !upstream.UpstreamActivitySnapshot {
	now := time.now()
	plan := req.normalized(now.unix(), now.unix_micro())
	event := plan.event_snapshot(websocket_upstream_provider_fixture)
	app.websocket.fixture_push_event(plan.instance, ws_event_from_upstream(event),
		app.providers.feishu.recent_event_limit)
	mut snapshot := plan.activity_snapshot(websocket_upstream_provider_fixture)
	if !app.engines.has_socket_workers() {
		app.websocket_upstream_record_activity(snapshot)
		return snapshot
	}
	outcome := app.kernel_dispatch_websocket_upstream_handled(app.kernel_websocket_upstream_dispatch_request(plan.activity_id,
		websocket_upstream_provider_fixture, plan.instance, plan.trace_id, plan.event_type,
		plan.message_id, plan.target, plan.target_type, plan.payload, plan.received_at,
		plan.metadata)) or {
		snapshot.worker_error = err.msg()
		snapshot.error_class = 'transport_error'
		app.websocket_upstream_record_activity(snapshot)
		return snapshot
	}
	resp := outcome.response
	if resp.error != '' {
		snapshot.worker_error = resp.error
		snapshot.error_class = resp.error_class
		app.websocket_upstream_record_activity(snapshot)
		return snapshot
	}
	snapshot.worker_handled = resp.handled
	snapshot.commands = outcome.command_snapshots
	snapshot.command_error = outcome.command_error
	app.websocket_upstream_record_activity(snapshot)
	return snapshot
}
