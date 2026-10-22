module main

import api.mcp.protocol as mcp_protocol
import upstream.transport
import time

fn queue_admission_route(retired chan bool) &mcp_protocol.SessionDispatch {
	return &mcp_protocol.SessionDispatch{
		provider:   'queue-test'
		retired_fn: fn [retired] () bool { return retired.len > 0 }
		call_fn:    fn (_ transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
			return transport.WorkerMcpDispatchResponse{}
		}
	}
}

fn queue_admission_seed(mut state mcp_protocol.McpState, route &mcp_protocol.SessionDispatch) {
	state.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
	mut session := state.sessions['s']
	session.pending = ['retained']
	session.last_activity_unix = 123
	state.sessions['s'] = session
}

fn test_direct_mcp_queue_rejects_messages_after_stop_without_mutation() {
	retired := chan bool{cap: 1}
	mut state := mcp_protocol.McpState{ max_pending_messages: 1 }
	queue_admission_seed(mut state, queue_admission_route(retired))
	state.request_stop()
	assert !state.do_queue('s', 'late').queued
	assert state.sessions['s'].pending == ['retained']
	assert state.sessions['s'].last_activity_unix == 123
	assert state.stat_pending_dropped_total == 0
}

fn test_app_mcp_queue_rejects_shutdown_before_sampling_accounting() {
	for policy in ['warn', 'drop', 'error'] {
		retired := chan bool{cap: 1}
		mut app := &App{}
		app.protocols.mcp.sampling_capability_policy = policy
		queue_admission_seed(mut app.protocols.mcp, queue_admission_route(retired))
		app.protocols.mcp.request_stop()
		result := McpRuntime.queue_message(mut app, 's', '{"method":"sampling/createMessage"}')
		assert !result.queued && !result.error
		assert app.protocols.mcp.sessions['s'].pending == ['retained']
		assert app.protocols.mcp.sessions['s'].last_activity_unix == 123
		assert app.protocols.mcp.stat_sampling_capability_warnings_total == 0
		assert app.protocols.mcp.stat_sampling_capability_dropped_total == 0
		assert app.protocols.mcp.stat_sampling_capability_errors_total == 0
	}
}

fn test_direct_mcp_queue_rejects_retired_route_before_session_scavenging() {
	retired := chan bool{cap: 1}
	mut state := mcp_protocol.McpState{ max_pending_messages: 1 }
	queue_admission_seed(mut state, queue_admission_route(retired))
	retired <- true
	assert !state.do_queue('s', 'late').queued
	assert state.sessions['s'].pending == ['retained']
	assert state.sessions['s'].last_activity_unix == 123
	assert state.stat_pending_dropped_total == 0
}

fn test_app_mcp_queue_rechecks_retirement_after_response_completion() {
	for explicit_route in [false, true] {
		retired := chan bool{cap: 1}
		route := queue_admission_route(retired)
		mut app := &App{}
		queue_admission_seed(mut app.protocols.mcp, route)
		retired <- true
		result := if explicit_route {
			McpRuntime.queue_message_for_dispatch(mut app, 's', 'late', route)
		} else {
			McpRuntime.queue_message(mut app, 's', 'late')
		}
		assert !result.queued
		assert app.protocols.mcp.sessions['s'].pending == ['retained']
		assert app.protocols.mcp.sessions['s'].last_activity_unix == 123
	}
}

fn test_active_and_unbound_mcp_queues_preserve_capacity_and_sampling_policy() {
	retired := chan bool{cap: 1}
	mut app := &App{}
	route := queue_admission_route(retired)
	queue_admission_seed(mut app.protocols.mcp, route)
	app.protocols.mcp.sessions['s'].last_activity_unix = time.now().unix()
	app.protocols.mcp.max_pending_messages = 1
	assert McpRuntime.queue_message_for_dispatch(mut app, 's', 'current', route).queued
	assert app.protocols.mcp.sessions['s'].pending == ['current']
	assert app.protocols.mcp.stat_pending_dropped_total == 1
	app.protocols.mcp.sampling_capability_policy = 'error'
	assert McpRuntime.queue_message(mut app, 's', '{"method":"sampling/createMessage"}').error
	assert app.protocols.mcp.stat_sampling_capability_errors_total == 1
	app.protocols.mcp.ensure_session('unbound', '', '', '', '')
	assert app.protocols.mcp.do_queue('unbound', 'direct').queued
	assert McpRuntime.queue_message(mut app, 'unbound', 'app').queued
	assert !McpRuntime.queue_message_for_dispatch(mut app, 'unbound', 'wrong', route).queued
}
