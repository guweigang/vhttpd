module relay

fn admission_frames(count int) []WireFrame {
	return []WireFrame{len: count, init: WireFrame{ kind: .data, id: 'frame-${index}', trace_id: 'trace' }}
}

fn test_initial_channel_buffer_cannot_bypass_its_limit() {
	mut registry := new_channel_registry(1)
	mut failed := false
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffer_limit: 1, buffered: admission_frames(2) }) or {
		failed = true
		assert err.msg() == 'relay_channel_buffer_full:channel'
	}
	assert failed
	assert registry.channels.len == 0
	assert registry.correlations.len == 0
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffer_limit: 1, buffered: admission_frames(1) }) or { panic(err) }
	assert registry.channels.len == 1
}

fn test_oversized_replacement_preserves_live_channel_frames_and_correlations() {
	mut registry := new_channel_registry(2)
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'original', buffer_limit: 2, buffered: admission_frames(1) }) or { panic(err) }
	registry.open_channel(RelayChannel{ id: 'peer', trace_id: 'peer' }) or { panic(err) }
	registry.bind_correlation('original-correlation', 'channel') or { panic(err) }
	registry.bind_correlation('peer-correlation', 'peer') or { panic(err) }
	mut failed := false
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'replacement', buffer_limit: 1, buffered: admission_frames(2) }) or { failed = true }
	assert failed
	assert registry.channels['channel'].trace_id == 'original'
	assert registry.channels['channel'].buffer_limit == 2
	assert registry.channels['channel'].open
	assert registry.channel_for_correlation('original-correlation') != none
	assert registry.channel_for_correlation('peer-correlation') != none
	frames := registry.drain('channel') or { panic(err) }
	assert frames.map(it.id) == ['frame-0']
}

fn test_initial_buffer_admission_uses_normalized_default_limit() {
	for limit in [0, -1] {
		mut registry := new_channel_registry(1)
		mut failed := false
		registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffer_limit: limit, buffered: admission_frames(65) }) or { failed = true }
		assert failed
		assert registry.channels.len == 0
		registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffer_limit: limit, buffered: admission_frames(64) }) or { panic(err) }
		assert registry.channels['channel'].buffer_limit == 64
		assert registry.channels['channel'].buffered.len == 64
	}
}

fn test_exact_initial_capacity_is_admitted_and_drain_releases_capacity() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffer_limit: 2, buffered: admission_frames(2) }) or { panic(err) }
	mut full := false
	registry.enqueue('channel', new_frame(.data, 'extra', 'trace')) or { full = true }
	assert full
	frames := registry.drain('channel') or { panic(err) }
	assert frames.map(it.id) == ['frame-0', 'frame-1']
	registry.enqueue('channel', new_frame(.data, 'after-drain', 'trace')) or { panic(err) }
	after := registry.drain('channel') or { panic(err) }
	assert after.map(it.id) == ['after-drain']
}

fn test_oversized_reopen_does_not_resurrect_a_closed_channel() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'original' }) or { panic(err) }
	registry.bind_correlation('old', 'channel') or { panic(err) }
	assert registry.close_channel('channel')
	mut failed := false
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'replacement', buffer_limit: 1, buffered: admission_frames(2) }) or { failed = true }
	assert failed
	assert !registry.channels['channel'].open
	assert registry.channels['channel'].trace_id == 'original'
	assert registry.channels['channel'].buffered.len == 0
	assert registry.correlations.len == 0
}
