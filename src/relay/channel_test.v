module relay

fn test_channel_registry_opens_channel_and_binds_correlation() {
	mut registry := new_channel_registry(2)
	registry.open_channel(RelayChannel{
		id:           'chan_1'
		node_id:      'local'
		route:        'site/main'
		trace_id:     'trace_1'
		buffer_limit: 2
	}) or { panic(err) }
	registry.bind_correlation('corr_1', 'chan_1') or { panic(err) }

	channel := registry.channel_for_correlation('corr_1') or { panic('missing channel') }

	assert channel.id == 'chan_1'
	assert channel.node_id == 'local'
	assert channel.route == 'site/main'
	assert channel.trace_id == 'trace_1'
	assert channel.open
}

fn test_channel_registry_enforces_channel_limit() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{
		id:       'chan_1'
		trace_id: 'trace_1'
	}) or { panic(err) }
	registry.open_channel(RelayChannel{
		id:       'chan_2'
		trace_id: 'trace_2'
	}) or {
		assert err.msg() == 'relay_channel_limit_exceeded:1'
		return
	}
	assert false
}

fn test_channel_registry_buffers_frames_with_limit_and_drain() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{
		id:           'chan_1'
		trace_id:     'trace_1'
		buffer_limit: 2
	}) or { panic(err) }

	registry.enqueue('chan_1', new_frame(.data, 'frm_1', 'trace_1')) or { panic(err) }
	registry.enqueue('chan_1', new_frame(.data, 'frm_2', 'trace_1')) or { panic(err) }
	registry.enqueue('chan_1', new_frame(.data, 'frm_3', 'trace_1')) or {
		assert err.msg() == 'relay_channel_buffer_full:chan_1'
	}

	frames := registry.drain('chan_1') or { panic(err) }

	assert frames.len == 2
	assert frames[0].id == 'frm_1'
	assert frames[1].id == 'frm_2'
	assert (registry.drain('chan_1') or { panic(err) }).len == 0
}

fn test_close_channel_clears_buffer_and_correlations() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{
		id:       'chan_1'
		trace_id: 'trace_1'
	}) or { panic(err) }
	registry.bind_correlation('corr_1', 'chan_1') or { panic(err) }
	registry.enqueue('chan_1', new_frame(.data, 'frm_1', 'trace_1')) or { panic(err) }

	assert registry.close_channel('chan_1')
	assert registry.channel_for_correlation('corr_1') == none
	registry.enqueue('chan_1', new_frame(.data, 'frm_2', 'trace_1')) or {
		assert err.msg() == 'relay_channel_closed:chan_1'
		return
	}
	assert false
}
