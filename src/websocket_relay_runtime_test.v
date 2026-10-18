module main

import relay
import runtime_plan
import dispatch
import ws

fn test_relay_websocket_path_descriptor_matches_explicit_hub_path() {
	mut app := App{}
	app.relay = relay.new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'hub'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'relay'
				}
				options: runtime_plan.PlanOptions{
					strings: {
						'path':    '/vhttpd/relay'
						'node_id': 'hub_1'
					}
				}
			}
		}
	}) or { panic(err) }

	descriptor := relay_websocket_path_descriptor(app.relay, '/vhttpd/relay?token=ignored') or {
		panic('missing relay')
	}
	missing := relay_websocket_path_descriptor(app.relay, '/ordinary/ws')

	assert descriptor.id == 'edge'
	assert missing == none
}

fn test_relay_websocket_event_fields_add_request_context() {
	mut app := &App{}
	mut state := app.build_relay_websocket_state(relay.RelayDescriptor{ id: 'edge' }, 'GET', '/vhttpd/relay', {}, {}, '', 'req_1', 'trace_1')
	state.conn_id = 'carrier_1'

	fields := relay_websocket_event_fields({
		'relay_event': 'inbound.registered'
		'frame_id':    'frm_1'
	}, state)

	assert fields['relay_event'] == 'inbound.registered'
	assert fields['trace_id'] == 'trace_1'
	assert fields['request_id'] == 'req_1'
	assert fields['path'] == '/vhttpd/relay'
	assert fields['relay_id'] == 'edge'
	assert fields['carrier_id'] == 'carrier_1'
	assert fields['frame_id'] == 'frm_1'
}

fn test_relay_registration_path_mismatch_rejects_other_relay_id() {
	mut app := &App{}
	mut state := app.build_relay_websocket_state(relay.RelayDescriptor{ id: 'edge' }, 'GET', '/vhttpd/relay', {}, {}, '', 'carrier_1', 'trace_1')

	mismatch := relay_registration_path_mismatch(state, relay.InboundOutcome{
		action:     .registered
		relay_id:   'other'
		carrier_id: 'carrier_1'
		trace_id:   'trace_2'
		frame_id:   'frm_1'
	}) or { panic('missing mismatch') }
	matched := relay_registration_path_mismatch(state, relay.InboundOutcome{
		action:   .registered
		relay_id: 'edge'
	})

	assert mismatch.action == .rejected
	assert mismatch.error == 'relay_websocket_relay_mismatch:other:edge'
	assert mismatch.trace_id == 'trace_2'
	assert matched == none
}

fn test_relay_websocket_finalize_cleans_the_owner_state_once() {
	mut app := &App{}
	mut state := app.build_relay_websocket_state(relay.RelayDescriptor{ id: 'edge' }, 'GET', '/relay', {}, {}, '', 'req', 'trace')
	app.websocket.state.conns['req'] = ws.HubConn{ id: 'req', lifecycle: state.lifecycle }
	app.websocket.state.pending['req'] = [ws.HubPendingMessage{ data: 'queued' }]
	relay_websocket_finalize(mut state)
	assert state.lifecycle.phase() == .closed
	assert 'req' !in app.websocket.state.conns
	assert 'req' !in app.websocket.state.pending
	relay_websocket_finalize(mut state)
	assert state.lifecycle.phase() == .closed
}

fn test_dispatch_event_services_keep_trace_and_required_event_sink() {
	mut control := &ControlPlaneRuntime{}
	mut services := dispatch.RuntimeServices(EventDispatchServices{
		trace:   'trace'
		emit_fn: fn [mut control] (kind string, fields map[string]string) {
			control.emit(kind, fields)
		}
	})
	assert services.trace_id() == 'trace'
	services.emit('http.request', {
		'status': '503'
	})
	assert control.http_stats.requests_total == 1
	assert control.http_stats.errors_total == 1
}
