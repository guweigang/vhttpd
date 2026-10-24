module relay

fn admission_open(correlation string) WireFrame {
	return WireFrame{ kind: .open, id: 'open', trace_id: 'new-trace', channel_id: 'slot', correlation_id: correlation, route: 'new-route' }
}

fn admission_existing(mut registry ChannelRegistry) {
	registry.open_channel(RelayChannel{ id: 'slot', trace_id: 'old-trace', node_id: 'old-node', route: 'old-route', buffer_limit: 2 }) or { panic(err) }
	registry.bind_correlation('old-correlation', 'slot') or { panic(err) }
	registry.enqueue('slot', WireFrame{ kind: .data, id: 'old-data', trace_id: 'old-trace', channel_id: 'slot', body: 'keep' }) or { panic(err) }
}

fn test_rejected_open_does_not_allocate_channel_or_consume_capacity() {
	mut registry := new_channel_registry(1)
	for correlation in [' ', '\t', '\n\r'] {
		outcome := handle_forward_frame(mut registry, admission_open(correlation), 'new-node', 8)
		assert outcome.action == .rejected
		assert outcome.error == 'relay_channel_missing_correlation_id'
		assert registry.channels.len == 0
		assert registry.correlations.len == 0
	}
	registry.open_channel(RelayChannel{ id: 'other', trace_id: 'trace' }) or { panic(err) }
	assert registry.channels.len == 1
}

fn test_rejected_reopen_preserves_live_channel_queue_and_correlations() {
	mut registry := new_channel_registry(1)
	admission_existing(mut registry)
	outcome := handle_forward_frame(mut registry, admission_open(' \t '), 'new-node', 8)
	assert outcome.action == .rejected
	assert registry.correlations['old-correlation'] == 'slot'
	channel := registry.channels['slot']
	assert channel.open
	assert channel.trace_id == 'old-trace'
	assert channel.node_id == 'old-node'
	assert channel.route == 'old-route'
	assert channel.buffer_limit == 2
	assert channel.buffered.map(it.id) == ['old-data']
	assert channel.buffered[0].body == 'keep'
}

fn test_rejected_reopen_does_not_reactivate_closed_channel() {
	mut registry := new_channel_registry(1)
	admission_existing(mut registry)
	assert registry.close_channel('slot')
	assert handle_forward_frame(mut registry, admission_open(' '), 'new-node', 8).action == .rejected
	assert !registry.channels['slot'].open
	assert registry.channels['slot'].trace_id == 'old-trace'
	assert registry.channels['slot'].buffered.len == 0
	assert registry.correlations.len == 0
}

fn test_outbound_tracking_rejection_preserves_existing_registration() {
	mut rt := empty_runtime()
	admission_existing(mut rt.channels)
	outbound := OutboundOutcome{ action: .ready, relay_id: 'relay', frame: admission_open(' ') }
	assert rt.track_outbound_delivery(outbound, 8).action == .rejected
	assert rt.channels.channels['slot'].trace_id == 'old-trace'
	assert rt.channels.correlations['old-correlation'] == 'slot'
	assert rt.channels.channels['slot'].buffered.map(it.id) == ['old-data']
}

fn test_valid_open_and_optional_correlation_keep_existing_semantics() {
	for correlation in ['', 'current', ' literal '] {
		mut registry := new_channel_registry(1)
		admission_existing(mut registry)
		outcome := handle_forward_frame(mut registry, admission_open(correlation), 'new-node', 8)
		assert outcome.action == .opened
		channel := registry.channels['slot']
		assert channel.trace_id == 'new-trace'
		assert channel.buffered.len == 0
		assert registry.channel_for_correlation('old-correlation') == none
		if correlation != '' {
			assert registry.correlations[correlation] == 'slot'
		} else {
			assert registry.correlations.len == 0
		}
	}
}
