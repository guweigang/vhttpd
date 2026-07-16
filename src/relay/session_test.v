module relay

fn test_session_registry_opens_endpoints_and_selects_targets_by_link_and_role() {
	mut registry := new_session_registry()
	registry.open_endpoint(RelayEndpoint{
		id:         'ep_client'
		channel_id: 'chan_client'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'consumer'
		trace_id:   'trace_1'
	}) or { panic(err) }
	registry.open_endpoint(RelayEndpoint{
		id:         'ep_server'
		channel_id: 'chan_server'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'producer'
		trace_id:   'trace_1'
	}) or { panic(err) }

	targets := registry.targets('session_1', 'link_1', 'producer', 'ep_client')

	assert targets.len == 1
	assert targets[0].id == 'ep_server'
	assert targets[0].channel_id == 'chan_server'
}

fn test_session_registry_buffers_and_drains_pending_frames_by_link() {
	mut registry := new_session_registry()
	registry.buffer_pending('session_1', 'link_1', WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_1'
		trace_id:   'trace_1'
		channel_id: 'chan_client'
		body:       'hello'
	}, 2) or { panic(err) }
	registry.buffer_pending('session_1', 'link_1', WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_2'
		trace_id:   'trace_1'
		channel_id: 'chan_client'
		body:       'world'
	}, 2) or { panic(err) }

	frames := registry.drain_pending('session_1', 'link_1')

	assert frames.len == 2
	assert frames[0].body == 'hello'
	assert frames[1].body == 'world'
	assert registry.drain_pending('session_1', 'link_1').len == 0
}

fn test_session_registry_enforces_pending_limit() {
	mut registry := new_session_registry()
	registry.buffer_pending('session_1', 'link_1', new_frame(.data, 'frm_1', 'trace_1'), 1) or {
		panic(err)
	}
	registry.buffer_pending('session_1', 'link_1', new_frame(.data, 'frm_2', 'trace_1'), 1) or {
		assert err.msg() == 'relay_session_pending_full:session_1:link_1'
		return
	}
	assert false
}

fn test_session_registry_close_endpoint_removes_empty_session() {
	mut registry := new_session_registry()
	registry.open_endpoint(RelayEndpoint{
		id:         'ep_client'
		channel_id: 'chan_client'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'consumer'
		trace_id:   'trace_1'
	}) or { panic(err) }

	assert registry.close_endpoint('session_1', 'ep_client')
	assert 'session_1' !in registry.sessions
}

fn test_session_registry_keeps_session_while_pending_frames_exist() {
	mut registry := new_session_registry()
	registry.open_endpoint(RelayEndpoint{
		id:         'ep_client'
		channel_id: 'chan_client'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'consumer'
		trace_id:   'trace_1'
	}) or { panic(err) }
	registry.buffer_pending('session_1', 'link_1', new_frame(.data, 'frm_1', 'trace_1'), 2) or {
		panic(err)
	}

	assert registry.close_endpoint('session_1', 'ep_client')
	assert 'session_1' in registry.sessions
	assert registry.drain_pending('session_1', 'link_1').len == 1
	assert 'session_1' !in registry.sessions
}
