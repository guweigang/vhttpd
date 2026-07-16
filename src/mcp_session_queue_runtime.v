module main

import api.mcp.protocol as mcp_protocol
import time

fn McpRuntime.queue_message(mut app App, session_id string, raw string) mcp_protocol.QueueResult {
	if session_id == '' || raw == '' {
		return mcp_protocol.QueueResult{
			queued: false
		}
	}
	mut warn_sampling_capability := false
	mut drop_sampling_capability := false
	mut error_sampling_capability := false
	mut session_trace_id := ''
	mut session_request_id := ''
	policy :=
		mcp_protocol.McpState.normalize_sampling_capability_policy(app.protocols.mcp.sampling_capability_policy)
	app.protocols.mcp.mu.@lock()
	if mut session := app.protocols.mcp.sessions[session_id] {
		session.last_activity_unix = time.now().unix()
		session_trace_id = session.trace_id
		session_request_id = session.request_id
		if raw.contains('"method":"sampling/createMessage"')
			|| raw.contains('"method": "sampling/createMessage"')
			|| raw.contains('"method":"sampling\\/createMessage"')
			|| raw.contains('"method": "sampling\\/createMessage"') {
			if !session.client_capabilities_json.contains('"sampling"') {
				match policy {
					'drop' { drop_sampling_capability = true }
					'error' { error_sampling_capability = true }
					else { warn_sampling_capability = true }
				}
			}
		}
		if !drop_sampling_capability && !error_sampling_capability {
			session.pending << raw
			max_pending := if app.protocols.mcp.max_pending_messages > 0 {
				app.protocols.mcp.max_pending_messages
			} else {
				128
			}
			if session.pending.len > max_pending {
				drop_count := session.pending.len - max_pending
				session.pending = session.pending[drop_count..].clone()
				app.mu.@lock()
				app.protocols.mcp.stat_pending_dropped_total += drop_count
				app.mu.unlock()
			}
		}
		app.protocols.mcp.sessions[session_id] = session
	}
	app.protocols.mcp.mu.unlock()
	if warn_sampling_capability {
		app.mu.@lock()
		app.protocols.mcp.stat_sampling_capability_warnings_total
		app.mu.unlock()
		app.emit('mcp.capability.warning', {
			'session_id':    session_id
			'request_id':    session_request_id
			'trace_id':      session_trace_id
			'warning_class': 'sampling_without_client_capability'
		})
	}
	if drop_sampling_capability {
		app.mu.@lock()
		app.protocols.mcp.stat_sampling_capability_dropped_total
		app.mu.unlock()
		app.emit('mcp.capability.drop', {
			'session_id': session_id
			'request_id': session_request_id
			'trace_id':   session_trace_id
			'policy':     policy
			'drop_class': 'sampling_without_client_capability'
		})
		return mcp_protocol.QueueResult{
			queued: false
		}
	}
	if error_sampling_capability {
		app.mu.@lock()
		app.protocols.mcp.stat_sampling_capability_errors_total
		app.mu.unlock()
		app.emit('mcp.capability.error', {
			'session_id':  session_id
			'request_id':  session_request_id
			'trace_id':    session_trace_id
			'policy':      policy
			'error_class': 'sampling_without_client_capability'
		})
		return mcp_protocol.QueueResult{
			queued:      false
			error:       true
			error_class: 'sampling_capability_required'
		}
	}
	return mcp_protocol.QueueResult{
		queued: true
	}
}
