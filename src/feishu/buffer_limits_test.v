module feishu

fn test_expiry_releases_idle_buffer_but_preserves_inflight_and_replacement() {
	mut state := FeishuState{}
	state.register_stream_buffer('idle', 'stream', 'main', '', '', 'old')
	state.register_stream_buffer('busy', 'busy-stream', 'main', '', '', 'busy')
	busy := state.buffer_snapshot('busy') or { panic('missing') }
	claim := state.begin_buffer_finish(busy) or { panic('missing claim') }
	idle := state.buffer_snapshot('idle') or { panic('missing') }
	releases := state.prune_expired_buffers_unlocked(idle.last_delta + buffer_ttl_ms + 1)
	assert releases.len == 1
	assert 'idle' !in state.buffers
	assert 'busy' in state.buffers
	state.cancel_buffer_finish(claim)
	state.register_stream_buffer('idle', 'new', 'main', '', '', 'replacement')
	assert state.buffer_snapshot('idle') or { panic('missing') }.stream_id == 'new'
}

fn test_oversize_buffer_is_rejected() {
	mut state := FeishuState{}
	state.register_stream_buffer('oversize', 'stream', 'main', '', '', 'x'.repeat(buffer_content_limit + 1))
	assert state.buffers.len == 0
}

fn test_expiry_preserves_generation_with_a_fresh_successor() {
	mut state := FeishuState{}
	state.register_stream_buffer('root', 'stream', 'main', '', '', 'content')
	mut root := state.buffers['root'] or { panic('missing') }
	root.last_delta = 1000
	root.last_flush = 1000
	state.buffers['root'] = root
	now := i64(1000) + buffer_ttl_ms + 1
	state.buffers['fresh'] = StreamBuffer{...root, message_id: 'fresh', last_delta: now}
	assert state.prune_expired_buffers_unlocked(now).len == 0
	assert state.buffers.len == 2
}

fn test_buffer_capacity_and_append_reject_without_mutation() {
	mut state := FeishuState{}
	state.register_stream_buffer('full', 'stream', 'main', '', '', 'x'.repeat(buffer_content_limit))
	command := state.admit_stream_command('full', 'stream', 'main') or { panic('missing') }
	state.append_stream_command(command, 'overflow') or {
		assert err.msg() == 'feishu_buffer_content_limit'
		assert state.buffers['full'].content.len == buffer_content_limit
		for index in 1 .. buffer_limit {
			state.buffers['occupied-${index}'] = StreamBuffer{message_id: 'occupied-${index}'}
		}
		state.register_stream_buffer('extra', 'other', 'main', '', '', '')
		assert 'extra' !in state.buffers
		return
	}
	assert false
}
