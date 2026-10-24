module main

import net.websocket
import relay

fn carrier_owner_hello(mut state RelayWebSocketBridgeState) {
	state.lifecycle.mark_open()
	frame := relay.registration_hello_frame(relay.RegistrationRequest{ node_id: 'node', relay_id: 'edge', mode: .agent, carrier: 'websocket', trace_id: state.trace_id, max_channels: 2 }) or { panic(err) }
	raw := relay.encode_frame(frame) or { panic(err) }
	mut client := &websocket.Client{}
	relay_websocket_message_cb(mut client, &websocket.Message{ opcode: .text_frame, payload: raw.bytes() }, state) or { panic(err) }
}

fn test_unregistered_relay_session_finalize_preserves_registered_carrier() {
	mut app := &App{}
	app.relay.register_carrier('edge', 'current') or { panic(err) }
	mut unregistered := app.build_relay_websocket_state(relay.RelayDescriptor{ id: 'edge' }, 'GET', '/relay', {}, {}, '', 'not-registered', 'trace')
	relay_websocket_finalize(mut unregistered)
	assert app.relay.carriers.carrier_id('edge') == 'current'
	assert app.relay.carriers.registered('edge')
}

fn carrier_owner_replacement_case(reuse_id bool) {
	mut app := &App{}
	mut old := app.build_relay_websocket_state(relay.RelayDescriptor{ id: 'edge' }, 'GET', '/relay', {}, {}, '', 'old', 'trace-old')
	old.conn_id = 'old'
	carrier_owner_hello(mut old)
	next_id := if reuse_id { 'old' } else { 'replacement' }
	mut current := app.build_relay_websocket_state(relay.RelayDescriptor{ id: 'edge' }, 'GET', '/relay', {}, {}, '', next_id, 'trace-new')
	current.conn_id = next_id
	carrier_owner_hello(mut current)
	relay_websocket_finalize(mut old)
	assert app.relay.carriers.registered('edge')
	assert app.relay.carriers.carrier_id('edge') == next_id
	relay_websocket_finalize(mut old)
	assert app.relay.carriers.registered('edge')
	relay_websocket_finalize(mut current)
	assert !app.relay.carriers.registered('edge')
}

fn test_retired_relay_session_cannot_detach_replacement() { carrier_owner_replacement_case(false) }

fn test_retired_relay_session_cannot_detach_reused_carrier_id() {
	carrier_owner_replacement_case(true)
}

fn test_relay_agent_detach_preserves_a_different_current_carrier() {
	mut app := &App{}
	ctx := app.build_relay_agent_runtime_context()
	descriptor := relay.RelayDescriptor{ id: 'edge' }
	ctx.on_carrier_attached(descriptor, 'old-agent', 'trace-old')
	ctx.on_carrier_attached(descriptor, 'new-agent', 'trace-new')
	ctx.on_carrier_detached(descriptor, 'old-agent', 'trace-old')
	assert app.relay.carriers.carrier_id('edge') == 'new-agent'
	assert app.relay.carriers.registered('edge')
	ctx.on_carrier_detached(descriptor, 'new-agent', 'trace-new')
	assert !app.relay.carriers.registered('edge')
}
