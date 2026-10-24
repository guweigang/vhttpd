module relay

import dispatch

@[heap]
struct PreparedBindingProbe {
mut:
	sends            int
	checks           int
	connected        bool = true
	replace_on_check bool
	replace_on_send  bool
	registry         CarrierRegistry
}

struct PreparedBindingCarrier {
	name  string
	probe &PreparedBindingProbe @[required]
}

fn (carrier PreparedBindingCarrier) id() string { return carrier.name }

fn (carrier PreparedBindingCarrier) connected() bool {
	mut probe := carrier.probe
	probe.checks++
	if probe.replace_on_check {
		probe.registry.register('edge', carrier.name) or { panic(err) }
	}
	return probe.connected
}

fn (mut carrier PreparedBindingCarrier) send(frame WireFrame) CarrierSendResult {
	mut probe := carrier.probe
	probe.sends++
	if probe.replace_on_send { probe.registry.register('edge', carrier.name) or { panic(err) } }
	return CarrierSendResult{ ok: true, trace_id: frame.trace_id, frame_id: frame.id }
}

fn (mut carrier PreparedBindingCarrier) close_channel(channel string, trace string) CarrierCloseResult {
	return CarrierCloseResult{ ok: true, channel_id: channel, trace_id: trace }
}

fn (mut carrier PreparedBindingCarrier) close() {}

fn prepared_binding_outbound(rt Runtime) OutboundOutcome {
	return rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace'
		'request_id': 'request'
		'channel_id': 'channel'
	}))
}

fn test_prepared_outbound_cannot_send_after_same_carrier_id_is_rebound() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	outbound := prepared_binding_outbound(rt)
	rt.register_carrier('edge', 'socket') or { panic(err) }
	probe := &PreparedBindingProbe{}
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	assert !send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 0
}

fn test_prepared_outbound_cannot_send_after_binding_is_removed() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	outbound := prepared_binding_outbound(rt)
	rt.unregister_carrier('edge', 'trace')
	probe := &PreparedBindingProbe{}
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	assert !send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 0
}

fn test_prepared_outbound_rejects_a_different_supplied_carrier() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	outbound := prepared_binding_outbound(rt)
	probe := &PreparedBindingProbe{}
	mut carrier := PreparedBindingCarrier{ name: 'other-socket', probe: probe }
	assert !send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 0
}

fn test_prepared_outbound_rechecks_registration_after_connected_callback() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	outbound := prepared_binding_outbound(rt)
	probe := &PreparedBindingProbe{ replace_on_check: true, registry: rt.carriers }
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	assert !send_to_carrier(mut carrier, outbound).ok
	assert probe.checks == 1
	assert probe.sends == 0
}

fn test_prepared_outbound_observes_replacement_through_a_registry_copy() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	outbound := prepared_binding_outbound(rt)
	mut copied := rt.carriers
	copied.register('edge', 'new-socket') or { panic(err) }
	probe := &PreparedBindingProbe{}
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	assert !send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 0
}

fn test_public_ready_fields_do_not_grant_an_unprepared_send_capability() {
	probe := &PreparedBindingProbe{}
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	outbound := OutboundOutcome{ action: .ready, relay_id: 'edge', carrier_id: 'socket', frame: WireFrame{ kind: .data, id: 'request', trace_id: 'trace', channel_id: 'channel' } }
	assert !send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 0
}

fn test_current_prepared_binding_sends_after_an_unrelated_binding_change() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	outbound := prepared_binding_outbound(rt)
	rt.register_carrier('other', 'socket') or { panic(err) }
	probe := &PreparedBindingProbe{}
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	assert send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 1
}

fn test_fresh_preparation_can_send_after_same_id_replacement() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	_ = prepared_binding_outbound(rt)
	rt.register_carrier('edge', 'socket') or { panic(err) }
	fresh := prepared_binding_outbound(rt)
	probe := &PreparedBindingProbe{}
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	assert send_to_carrier(mut carrier, fresh).ok
	assert probe.sends == 1
}

fn test_outbound_public_route_fields_cannot_redirect_its_prepared_capability() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	rt.register_carrier('other', 'socket') or { panic(err) }
	original := prepared_binding_outbound(rt)
	for changed in [OutboundOutcome{ ...original, relay_id: 'other' },
		OutboundOutcome{ ...original, carrier_id: 'other-socket' }] {
		probe := &PreparedBindingProbe{}
		mut carrier := PreparedBindingCarrier{ name: changed.carrier_id, probe: probe }
		assert !send_to_carrier(mut carrier, changed).ok
		assert probe.sends == 0
	}
}

fn test_admitted_send_callback_can_rebind_without_losing_its_completion() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'socket') or { panic(err) }
	outbound := prepared_binding_outbound(rt)
	probe := &PreparedBindingProbe{ replace_on_send: true, registry: rt.carriers }
	mut carrier := PreparedBindingCarrier{ name: 'socket', probe: probe }
	assert send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 1
	assert !send_to_carrier(mut carrier, outbound).ok
	assert probe.sends == 1
}
