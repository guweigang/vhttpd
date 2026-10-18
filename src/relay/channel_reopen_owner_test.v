module relay

fn reopened_channel(trace string) RelayChannel {
	return RelayChannel{ id: 'slot', trace_id: trace }
}

fn channel_reopen_registry() ChannelRegistry {
	mut registry := new_channel_registry(2)
	registry.open_channel(reopened_channel('old-trace')) or { panic(err) }
	registry.bind_correlation('old-correlation', 'slot') or { panic(err) }
	registry.open_channel(reopened_channel('new-trace')) or { panic(err) }
	registry.bind_correlation('new-correlation', 'slot') or { panic(err) }
	return registry
}

fn test_channel_reopen_retires_only_correlations_still_owned_by_that_channel() {
	mut registry := new_channel_registry(2)
	registry.open_channel(reopened_channel('old-trace')) or { panic(err) }
	registry.open_channel(RelayChannel{ id: 'peer', trace_id: 'peer-trace' }) or { panic(err) }
	registry.bind_correlation('old-a', 'slot') or { panic(err) }
	registry.bind_correlation('old-b', 'slot') or { panic(err) }
	registry.bind_correlation('moved', 'slot') or { panic(err) }
	registry.bind_correlation('moved', 'peer') or { panic(err) }
	registry.open_channel(reopened_channel('new-trace')) or { panic(err) }
	assert registry.channel_for_correlation('old-a') == none
	assert registry.channel_for_correlation('old-b') == none
	peer := registry.channel_for_correlation('moved') or { panic('peer correlation lost') }
	assert peer.id == 'peer'
	assert registry.correlations.len == 1
	registry.bind_correlation('new', 'slot') or { panic(err) }
	assert registry.channel_for_correlation('new')?.trace_id == 'new-trace'
}

fn test_repeated_channel_reopen_bounds_correlation_lifetime_at_capacity() {
	mut registry := new_channel_registry(1)
	for i in 0 .. 20 {
		registry.open_channel(reopened_channel('trace-${i}')) or { panic(err) }
		registry.bind_correlation('corr-${i}', 'slot') or { panic(err) }
		assert registry.channels.len == 1
		assert registry.correlations.len == 1
	}
	assert registry.close_channel('slot')
	assert registry.correlations.len == 0
	registry.open_channel(reopened_channel('last')) or { panic(err) }
	registry.bind_correlation('last', 'slot') or { panic(err) }
	assert registry.retire_channel('slot')
	assert registry.correlations.len == 0
	assert registry.channels.len == 0
}

fn test_stale_correlation_cannot_enqueue_into_reopened_channel() {
	mut registry := channel_reopen_registry()
	stale := WireFrame{ version: wire_version, kind: .data, id: 'late-data', channel_id: 'missing', correlation_id: 'old-correlation', trace_id: 'old-trace', body: 'late' }
	rejected := handle_forward_frame(mut registry, stale, 'node', 2)
	assert rejected.action == .rejected
	assert rejected.error == 'relay_forward_unknown_channel'
	empty := registry.drain('slot') or { panic(err) }
	assert empty.len == 0
	current := WireFrame{ ...stale, id: 'current-data', correlation_id: 'new-correlation', trace_id: 'new-trace' }
	assert handle_forward_frame(mut registry, current, 'node', 2).action == .queued
	frames := registry.drain('slot') or { panic(err) }
	assert frames.map(it.id) == ['current-data']
}

fn test_stale_correlation_cannot_close_reopened_channel() {
	for kind in [WireFrameKind.end, .cancel, .error] {
		mut registry := channel_reopen_registry()
		stale := WireFrame{ version: wire_version, kind: kind, id: 'late-close', channel_id: 'missing', correlation_id: 'old-correlation', trace_id: 'old-trace' }
		assert handle_forward_frame(mut registry, stale, 'node', 2).action == .rejected
		assert registry.channels['slot'].open
		current := WireFrame{ ...stale, id: 'current-close', correlation_id: 'new-correlation', trace_id: 'new-trace' }
		assert handle_forward_frame(mut registry, current, 'node', 2).action == .closed
		assert registry.correlations.len == 0
	}
}

fn test_invalid_channel_reopen_preserves_existing_correlations_and_buffer() {
	mut registry := new_channel_registry(1)
	registry.open_channel(reopened_channel('old-trace')) or { panic(err) }
	registry.bind_correlation('old', 'slot') or { panic(err) }
	registry.enqueue('slot', new_frame(.data, 'pending', 'old-trace')) or { panic(err) }
	mut failed := false
	registry.open_channel(reopened_channel('')) or { failed = true }
	assert failed
	assert registry.channel_for_correlation('old')?.trace_id == 'old-trace'
	frames := registry.drain('slot') or { panic(err) }
	assert frames.map(it.id) == ['pending']
}
