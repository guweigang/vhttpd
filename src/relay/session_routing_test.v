module relay

fn test_route_session_frame_delivers_to_matching_targets() {
	mut registry := new_session_registry()
	registry.open_endpoint(RelayEndpoint{
		id:         'consumer_1'
		channel_id: 'chan_consumer'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'consumer'
		trace_id:   'trace_1'
	}) or { panic(err) }
	registry.open_endpoint(RelayEndpoint{
		id:         'producer_1'
		channel_id: 'chan_producer'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'producer'
		trace_id:   'trace_1'
	}) or { panic(err) }

	outcome := route_session_frame(mut registry, 'session_1', 'link_1', 'consumer_1',
		'producer', new_frame(.data, 'frm_1', 'trace_1'), 2)

	assert outcome.action == .deliver
	assert outcome.target_ids == ['producer_1']
	assert outcome.buffered_len == 0
}

fn test_route_session_frame_buffers_when_no_target_exists() {
	mut registry := new_session_registry()
	registry.open_endpoint(RelayEndpoint{
		id:         'consumer_1'
		channel_id: 'chan_consumer'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'consumer'
		trace_id:   'trace_1'
	}) or { panic(err) }

	outcome := route_session_frame(mut registry, 'session_1', 'link_1', 'consumer_1',
		'producer', new_frame(.data, 'frm_1', 'trace_1'), 2)

	assert outcome.action == .buffered
	assert outcome.buffered_len == 1
	assert registry.sessions['session_1'].pending_by_link['link_1'].len == 1
}

fn test_open_session_endpoint_and_drain_returns_pending_frames() {
	mut registry := new_session_registry()
	route_session_frame(mut registry, 'session_1', 'link_1', 'consumer_1', 'producer',
		new_frame(.data, 'frm_1', 'trace_1'), 2)
	route_session_frame(mut registry, 'session_1', 'link_1', 'consumer_1', 'producer',
		new_frame(.data, 'frm_2', 'trace_1'), 2)

	frames := open_session_endpoint_and_drain(mut registry, RelayEndpoint{
		id:         'producer_1'
		channel_id: 'chan_producer'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'producer'
		trace_id:   'trace_1'
	}) or { panic(err) }

	assert frames.len == 2
	assert frames[0].id == 'frm_1'
	assert frames[1].id == 'frm_2'
	assert registry.sessions['session_1'].pending_by_link.len == 0
}

fn test_route_session_frame_rejects_when_pending_limit_is_full() {
	mut registry := new_session_registry()
	route_session_frame(mut registry, 'session_1', 'link_1', 'consumer_1', 'producer',
		new_frame(.data, 'frm_1', 'trace_1'), 1)

	outcome := route_session_frame(mut registry, 'session_1', 'link_1', 'consumer_1',
		'producer', new_frame(.data, 'frm_2', 'trace_1'), 1)

	assert outcome.action == .rejected
	assert outcome.error == 'relay_session_pending_full:session_1:link_1'
}
