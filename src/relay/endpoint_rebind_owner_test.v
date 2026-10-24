module relay

fn rebind_endpoint(id string, link string) RelayEndpoint {
	return RelayEndpoint{ id: id, channel_id: 'channel-' + link, session_id: 'session', link_id: link, role: 'producer', trace_id: 'trace-' + link }
}

fn test_rebinding_endpoint_retires_its_old_link_index() {
	mut registry := new_session_registry()
	registry.open_endpoint(rebind_endpoint('moving', 'old')) or { panic(err) }
	registry.open_endpoint(rebind_endpoint('moving', 'new')) or { panic(err) }
	assert registry.targets('session', 'old', '', '').len == 0
	assert 'old' !in registry.sessions['session'].endpoints_by_link
	targets := registry.targets('session', 'new', 'producer', '')
	assert targets.len == 1
	assert targets[0].channel_id == 'channel-new'
}

fn test_rebinding_and_closing_preserve_other_endpoints_and_link_pending() {
	mut registry := new_session_registry()
	registry.open_endpoint(rebind_endpoint('moving', 'old')) or { panic(err) }
	registry.open_endpoint(rebind_endpoint('peer', 'old')) or { panic(err) }
	registry.buffer_pending('session', 'old', new_frame(.data, 'pending', 'trace'), 2) or { panic(err) }
	registry.open_endpoint(rebind_endpoint('moving', 'new')) or { panic(err) }
	assert registry.sessions['session'].endpoints_by_link['old'] == ['peer']
	assert registry.targets('session', 'old', '', '').map(it.id) == ['peer']
	assert registry.close_endpoint('session', 'moving')
	assert 'new' !in registry.sessions['session'].endpoints_by_link
	assert registry.close_endpoint('session', 'peer')
	assert registry.sessions['session'].endpoints_by_link.len == 0
	pending := registry.drain_pending('session', 'old')
	assert pending.len == 1
	assert pending[0].id == 'pending'
	assert 'session' !in registry.sessions
}

fn test_repeated_rebinding_does_not_accumulate_links_or_duplicate_targets() {
	mut registry := new_session_registry()
	for i in 0 .. 20 {
		link := 'link-${i % 3}'
		registry.open_endpoint(rebind_endpoint('moving', link)) or { panic(err) }
		registry.open_endpoint(rebind_endpoint('moving', link)) or { panic(err) }
		assert registry.sessions['session'].endpoints_by_link.len == 1
		assert registry.targets('session', link, '', '').map(it.id) == ['moving']
	}
	assert registry.close_endpoint('session', 'moving')
	assert 'session' !in registry.sessions
}

fn test_old_link_routes_to_pending_until_its_own_endpoint_opens() {
	mut registry := new_session_registry()
	registry.open_endpoint(rebind_endpoint('moving', 'old')) or { panic(err) }
	registry.open_endpoint(rebind_endpoint('moving', 'new')) or { panic(err) }
	old := route_session_frame(mut registry, 'session', 'old', 'source', 'producer', new_frame(.data, 'old-frame', 'trace'), 2)
	assert old.action == .buffered
	assert old.target_ids.len == 0
	current := route_session_frame(mut registry, 'session', 'new', 'source', 'producer', new_frame(.data, 'new-frame', 'trace'), 2)
	assert current.action == .deliver
	assert current.target_ids == ['moving']
	pending := open_session_endpoint_and_drain(mut registry, rebind_endpoint('replacement', 'old')) or { panic(err) }
	assert pending.len == 1
	assert pending[0].id == 'old-frame'
	assert registry.targets('session', 'old', '', '').map(it.id) == ['replacement']
}

fn test_invalid_rebind_keeps_existing_registration_and_pending_frames() {
	mut registry := new_session_registry()
	registry.open_endpoint(rebind_endpoint('moving', 'old')) or { panic(err) }
	registry.buffer_pending('session', 'old', new_frame(.data, 'pending', 'trace'), 2) or { panic(err) }
	mut failed := false
	registry.open_endpoint(RelayEndpoint{ ...rebind_endpoint('moving', 'new'), trace_id: '' }) or { failed = true }
	assert failed
	assert registry.targets('session', 'old', '', '').map(it.id) == ['moving']
	assert registry.targets('session', 'new', '', '').len == 0
	assert registry.sessions['session'].pending_by_link['old'].len == 1
}
