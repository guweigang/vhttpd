module relay

fn test_forward_open_frame_creates_channel_and_binds_correlation() {
	mut registry := new_channel_registry(4)
	frame := WireFrame{
		version:        wire_version
		kind:           .open
		id:             'frm_open'
		trace_id:       'trace_1'
		channel_id:     'chan_1'
		correlation_id: 'corr_1'
		route:          'site/main'
	}

	outcome := handle_forward_frame(mut registry, frame, 'agent_1', 2)

	assert outcome.action == .opened
	assert outcome.channel_id == 'chan_1'
	assert registry.channels['chan_1'].node_id == 'agent_1'
	assert registry.channels['chan_1'].route == 'site/main'
	assert registry.channels['chan_1'].buffer_limit == 2
	assert registry.channel_for_correlation('corr_1')?.id == 'chan_1'
}

fn test_forward_data_frame_queues_on_existing_channel() {
	mut registry := new_channel_registry(4)
	handle_forward_frame(mut registry, WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'agent_1', 2)

	outcome := handle_forward_frame(mut registry, WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_data'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
		body:       'payload'
	}, 'agent_1', 2)
	frames := registry.drain('chan_1') or { panic(err) }

	assert outcome.action == .queued
	assert frames.len == 1
	assert frames[0].id == 'frm_data'
	assert frames[0].body == 'payload'
}

fn test_forward_data_frame_can_resolve_channel_by_correlation() {
	mut registry := new_channel_registry(4)
	handle_forward_frame(mut registry, WireFrame{
		version:        wire_version
		kind:           .open
		id:             'frm_open'
		trace_id:       'trace_1'
		channel_id:     'chan_1'
		correlation_id: 'corr_1'
	}, 'agent_1', 2)

	outcome := handle_forward_frame(mut registry, WireFrame{
		version:        wire_version
		kind:           .data
		id:             'frm_data'
		trace_id:       'trace_1'
		channel_id:     'chan_missing'
		correlation_id: 'corr_1'
		body:           'payload'
	}, 'agent_1', 2)

	assert outcome.action == .queued
	assert outcome.channel_id == 'chan_1'
}

fn test_forward_end_frame_closes_channel_and_clears_correlation() {
	mut registry := new_channel_registry(4)
	handle_forward_frame(mut registry, WireFrame{
		version:        wire_version
		kind:           .open
		id:             'frm_open'
		trace_id:       'trace_1'
		channel_id:     'chan_1'
		correlation_id: 'corr_1'
	}, 'agent_1', 2)

	outcome := handle_forward_frame(mut registry, WireFrame{
		version:    wire_version
		kind:       .end
		id:         'frm_end'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'agent_1', 2)

	assert outcome.action == .closed
	assert !registry.channels['chan_1'].open
	assert registry.channel_for_correlation('corr_1') == none
}

fn test_forward_data_frame_reports_buffer_full_as_rejected_outcome() {
	mut registry := new_channel_registry(4)
	handle_forward_frame(mut registry, WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'agent_1', 1)
	handle_forward_frame(mut registry, WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_data_1'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'agent_1', 1)

	outcome := handle_forward_frame(mut registry, WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_data_2'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'agent_1', 1)

	assert outcome.action == .rejected
	assert outcome.error == 'relay_channel_buffer_full:chan_1'
}
