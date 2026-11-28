module relay

fn test_inbound_request_retirement_is_bounded_and_cannot_delete_reopened_channel() ! {
	mut rt := empty_runtime()
	for i in 0 .. 1200 {
		frame := WireFrame{ version: wire_version, kind: .open, id: 'request-${i}', channel_id: 'request-${i}', trace_id: 'trace' }
		accepted := rt.handle_inbound_frame('carrier', frame, 4)
		assert accepted.action == .forwarded
		assert rt.finish_inbound_delivery(accepted.forwarding.lease)
		assert !rt.finish_inbound_delivery(accepted.forwarding.lease)
	}
	assert rt.channels.channels.len == 0
	frame := WireFrame{ version: wire_version, kind: .open, id: 'same', channel_id: 'same', trace_id: 'trace' }
	old := rt.handle_inbound_frame('carrier', frame, 4)
	fresh := rt.handle_inbound_frame('carrier', frame, 4)
	assert !rt.finish_inbound_delivery(old.forwarding.lease)
	assert rt.channels.channels.len == 1
	assert rt.finish_inbound_delivery(fresh.forwarding.lease)
	assert rt.channels.channels.len == 0
}
