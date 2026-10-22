module relay

fn owned_queue_frame() WireFrame {
	return WireFrame{
		kind:       .data
		id:         'original'
		trace_id:   'trace'
		channel_id: 'channel'
		metadata:   {
			'tag': 'original'
		}
		headers:    {
			'x-owner': 'original'
		}
	}
}

// Value-returning consumers can mutate their own map/array variables. Queue
// admission and lookup must not give those variables aliases of retained data.
fn queue_metadata(values map[string]string) map[string]string { return values }

fn queue_headers(values map[string]string) map[string]string { return values }

fn queue_buffer(values []WireFrame) []WireFrame { return values }

fn change_queue_frame_maps(frame WireFrame) {
	mut metadata := queue_metadata(frame.metadata)
	metadata['tag'] = 'changed'
	mut headers := queue_headers(frame.headers)
	headers['x-owner'] = 'changed'
}

fn test_channel_enqueue_owns_frame_maps() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace' }) or { panic(err) }
	frame := owned_queue_frame()
	registry.enqueue('channel', frame) or { panic(err) }
	change_queue_frame_maps(frame)
	frames := registry.drain('channel') or { panic(err) }
	assert frames[0].metadata['tag'] == 'original'
	assert frames[0].headers['x-owner'] == 'original'
}

fn test_pending_session_queue_owns_frame_maps() {
	mut registry := new_session_registry()
	frame := owned_queue_frame()
	registry.buffer_pending('session', 'link', frame, 2) or { panic(err) }
	change_queue_frame_maps(frame)
	frames := registry.drain_pending('session', 'link')
	assert frames[0].metadata['tag'] == 'original'
	assert frames[0].headers['x-owner'] == 'original'
	assert 'session' !in registry.sessions
}

fn test_channel_open_owns_initial_buffer_array() {
	mut registry := new_channel_registry(1)
	supplied := RelayChannel{ id: 'channel', trace_id: 'trace', buffered: [owned_queue_frame()] }
	registry.open_channel(supplied) or { panic(err) }
	mut frames := queue_buffer(supplied.buffered)
	frames[0] = WireFrame{ ...owned_queue_frame(), id: 'changed' }
	retained := registry.drain('channel') or { panic(err) }
	assert retained[0].id == 'original'
}

fn test_channel_open_owns_nested_initial_frame_maps() {
	mut registry := new_channel_registry(1)
	frame := owned_queue_frame()
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffered: [frame] }) or { panic(err) }
	change_queue_frame_maps(frame)
	retained := registry.drain('channel') or { panic(err) }
	assert retained[0].metadata['tag'] == 'original'
	assert retained[0].headers['x-owner'] == 'original'
}

fn test_correlation_lookup_returns_an_owned_buffer_snapshot() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffered: [owned_queue_frame()] }) or { panic(err) }
	registry.bind_correlation('corr', 'channel') or { panic(err) }
	snapshot := registry.channel_for_correlation('corr') or { panic('missing channel') }
	change_queue_frame_maps(snapshot.buffered[0])
	mut frames := queue_buffer(snapshot.buffered)
	frames[0] = WireFrame{ ...owned_queue_frame(), id: 'changed' }
	retained := registry.drain('channel') or { panic(err) }
	assert retained[0].id == 'original'
	assert retained[0].metadata['tag'] == 'original'
	assert retained[0].headers['x-owner'] == 'original'
}

fn test_drained_returned_frame_does_not_alias_remaining_queued_frame() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace' }) or { panic(err) }
	frame := owned_queue_frame()
	registry.enqueue('channel', WireFrame{ ...frame, id: 'relay-response:request', exchange_kind: 'response' }) or { panic(err) }
	registry.enqueue('channel', frame) or { panic(err) }
	returned := registry.drain_returned('channel') or { panic(err) }
	assert returned.len == 1
	change_queue_frame_maps(returned[0])
	retained := registry.drain('channel') or { panic(err) }
	assert retained.len == 1
	assert retained[0].metadata['tag'] == 'original'
	assert retained[0].headers['x-owner'] == 'original'
}

fn test_correlation_lookup_owns_nested_frame_maps() {
	mut registry := new_channel_registry(1)
	registry.open_channel(RelayChannel{ id: 'channel', trace_id: 'trace', buffered: [owned_queue_frame()] }) or { panic(err) }
	registry.bind_correlation('corr', 'channel') or { panic(err) }
	snapshot := registry.channel_for_correlation('corr') or { panic('missing channel') }
	change_queue_frame_maps(snapshot.buffered[0])
	retained := registry.drain('channel') or { panic(err) }
	assert retained[0].metadata['tag'] == 'original'
	assert retained[0].headers['x-owner'] == 'original'
}
