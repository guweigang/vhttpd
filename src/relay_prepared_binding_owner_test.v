module main

import dispatch
import relay
import ws

fn prepared_binding_app() &App {
	mut app := &App{}
	app.relay.register_carrier('edge', 'socket') or { panic(err) }
	app.websocket.state.conns['socket'] = ws.HubConn{ id: 'socket', lifecycle: &ws.DispatchConnState{} }
	return app
}

fn test_prepared_relay_send_does_not_queue_into_rebound_socket() {
	mut app := prepared_binding_app()
	outbound := app.relay.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace'
		'request_id': 'request'
		'channel_id': 'channel'
	}))
	app.relay.register_carrier('edge', 'socket') or { panic(err) }
	app.websocket.state.conns['socket'] = ws.HubConn{ id: 'socket', lifecycle: &ws.DispatchConnState{} }
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'socket')
	assert !relay.send_to_carrier(mut carrier, outbound).ok
	assert 'socket' !in app.websocket.state.pending
	fresh := app.relay.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace'
		'request_id': 'request'
		'channel_id': 'channel'
	}))
	assert relay.send_to_carrier(mut carrier, fresh).ok
	assert app.websocket.state.pending['socket'].len == 1
}

fn test_rejected_prepared_wait_send_releases_its_channel_without_queueing() {
	mut app := prepared_binding_app()
	outbound := app.relay.prepare_outbound_delivery(dispatch.relay_delivery_outcome_with_completion('relay:edge', {
		'trace_id':   'trace'
		'request_id': 'request'
		'channel_id': 'channel'
		'frame_kind': 'open'
	}, 'wait', 1))
	assert app.relay.track_outbound_delivery(outbound, 4).action == .opened
	app.relay.register_carrier('edge', 'socket') or { panic(err) }
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'socket')
	sent := relay.send_to_carrier(mut carrier, outbound)
	assert !sent.ok
	result := relay_delivery_send_http_outcome(mut app.relay, outbound, sent)
	assert result.kind == .failure
	assert result.status == 503
	assert 'socket' !in app.websocket.state.pending
	assert app.relay.snapshot().channel_count == 0
	assert app.relay.carriers.registered('edge')
}

fn test_prepared_relay_send_cannot_use_another_live_socket() {
	mut app := prepared_binding_app()
	outbound := app.relay.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace'
		'request_id': 'request'
		'channel_id': 'channel'
	}))
	app.websocket.state.conns['other'] = ws.HubConn{ id: 'other', lifecycle: &ws.DispatchConnState{} }
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'other')
	assert !relay.send_to_carrier(mut carrier, outbound).ok
	assert app.websocket.state.pending.len == 0
}
