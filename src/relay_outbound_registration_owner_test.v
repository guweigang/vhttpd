module main

import relay

fn http_owned_outbound() relay.OutboundOutcome {
	return relay.OutboundOutcome{
		action:     .ready
		relay_id:   'edge'
		trace_id:   'same-trace'
		frame_id:   'same-request'
		completion: relay.ResponseCompletionPolicy{ mode: 'wait', timeout_ms: 1 }
		frame:      relay.WireFrame{ kind: .open, id: 'same-request', channel_id: 'slot', trace_id: 'same-trace', correlation_id: 'same-correlation' }
	}
}

fn test_http_old_wait_does_not_take_new_response_or_retire_new_channel() {
	mut rt := relay.empty_runtime()
	old := http_owned_outbound()
	next := http_owned_outbound()
	rt.track_outbound_delivery(old, 4)
	rt.track_outbound_delivery(next, 4)
	rt.handle_frame(relay.WireFrame{ kind: .data, id: 'relay-response:same-request', channel_id: 'slot', trace_id: 'same-trace', exchange_kind: 'response', body: 'new' }, 'edge', 4)
	result := relay_delivery_wait_http_outcome(mut rt, old, relay.CarrierSendResult{ ok: true })
	assert result.kind == .failure
	assert 'slot' in rt.channels.channels
	current := relay_delivery_wait_http_outcome(mut rt, next, relay.CarrierSendResult{ ok: true })
	assert current.kind == .response
	assert current.body == 'new'
	assert 'slot' !in rt.channels.channels
}

fn test_http_old_wait_without_response_preserves_new_channel() {
	mut rt := relay.empty_runtime()
	old := http_owned_outbound()
	next := http_owned_outbound()
	rt.track_outbound_delivery(old, 4)
	rt.track_outbound_delivery(next, 4)
	result := relay_delivery_wait_http_outcome(mut rt, old, relay.CarrierSendResult{ ok: true })
	assert result.kind == .failure
	assert 'slot' in rt.channels.channels
	assert rt.channels.correlations['same-correlation'] == 'slot'
	assert rt.finish_outbound_delivery(next).action == .closed
}

fn test_http_old_send_failure_preserves_new_channel() {
	mut rt := relay.empty_runtime()
	old := http_owned_outbound()
	next := http_owned_outbound()
	rt.track_outbound_delivery(old, 4)
	rt.track_outbound_delivery(next, 4)
	result := relay_delivery_wait_http_outcome(mut rt, old, relay.CarrierSendResult{ ok: false, error: 'disconnected' })
	assert result.kind == .failure
	assert 'slot' in rt.channels.channels
	assert rt.finish_outbound_delivery(next).action == .closed
}
