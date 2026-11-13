module main

import executor
import time

// An allowlist at collection time protects every consumer (including future
// UIs). Never retain frames, SQL, bindings, parameters, bearer tokens or bodies.
fn (mut control ControlPlaneRuntime) record_relay_event(kind string, fields map[string]string) {
	if !kind.starts_with('relay.takeover.') && kind != 'relay.database.request'
		&& kind !in ['relay.agent.disconnected', 'relay.agent.reconnect_scheduled', 'relay.agent.handshake', 'relay.carrier.attach', 'relay.carrier.detach', 'relay.websocket.attached', 'relay.registration']
		&& fields['error_class'] == '' && fields['action'] !in ['failed', 'rejected'] { return }
	mut safe := map[string]string{}
	for key in ['relay_id', 'node_id', 'carrier_id', 'channel_id', 'trace_id', 'request_id',
		'route', 'path', 'method', 'execution', 'status', 'duration_ms', 'phase',
		'operation', 'resource', 'driver', 'request_bytes', 'response_bytes',
		'attempt', 'state', 'next_attempt_at_ms', 'action', 'relay_event', 'error_class'] {
		if value := fields[key] {
			safe[key] = if value.len > 256 { value[..256] } else { value }
		}
	}
	previous := control.relay_diagnostics
	mut events := previous.events.clone()
	serial := previous.serial + 1
	events << executor.AdminRelayEvent{serial: serial, at_ms: time.now().unix_milli(), kind: kind, fields: safe}
	if events.len > 256 { events = events[events.len - 256..].clone() }
	completed := fields['phase'] == 'completed'
	failed := completed && (fields['status'].int() >= 400 || fields['error_class'] != '')
	control.relay_diagnostics = executor.AdminRelayDiagnostics{
		serial: serial
		completed: previous.completed + if completed { u64(1) } else { u64(0) }
		failed: previous.failed + if failed { u64(1) } else { u64(0) }
		retained: events.len
		events: events
	}
}

fn (mut control ControlPlaneRuntime) relay_diagnostics_snapshot() executor.AdminRelayDiagnostics {
	control.mu.@lock()
	defer { control.mu.unlock() }
	return control.relay_diagnostics
}
