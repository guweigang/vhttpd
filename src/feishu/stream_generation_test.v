module feishu

fn test_wire_generation_rejects_identical_id_aba_and_missing_generation() {
	mut state := FeishuState{}
	state.register_stream_buffer('message', 'stream', 'main', '', '', 'old')
	old := state.buffer_snapshot('message') or { panic('missing') }
	assert old.generation != ''
	assert state.admit_wire_stream_command('message', 'stream', 'main', old.generation) != none
	for clear in [false, true] {
		if clear { state.clear_buffer('message') }
		state.register_stream_buffer('message', 'stream', 'main', '', '', 'new')
		current := state.buffer_snapshot('message') or { panic('missing') }
		assert current.generation != old.generation
		assert state.admit_wire_stream_command('message', 'stream', 'main', old.generation) == none
		assert state.admit_wire_stream_command('message', 'stream', 'main', '') == none
		assert state.admit_wire_stream_command('message', 'stream', 'main', current.generation) != none
	}
}

fn test_initial_send_preserves_producer_generation_and_bridge_mirror() {
	mut remote := FeishuState{}
	claim := remote.begin_initial_send('stream')
	remote.mu.@lock()
	assert remote.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', '', 'producer-generation')
	generation := remote.stream_generation_unlocked('message')
	remote.mu.unlock()
	remote.finish_initial_send(claim)
	mut mirror := FeishuState{}
	local := mirror.begin_initial_send('stream')
	mirror.mu.@lock()
	assert mirror.commit_initial_send_generation_unlocked(local, 'message', 'main', '', '', '', generation)
	mirror.mu.unlock()
	mirror.finish_initial_send(local)
	assert mirror.admit_wire_stream_command('message', 'stream', 'main', generation) != none
	assert remote.admit_wire_stream_command('message', 'stream', 'main', generation) != none
	remote.register_stream_buffer('message', 'stream', 'main', '', '', '')
	assert remote.admit_wire_stream_command('message', 'stream', 'main', generation) == none
}

fn test_retired_initial_send_cannot_install_a_wire_generation() {
	mut state := FeishuState{}
	claim := state.begin_initial_send('stream')
	state.register_stream_buffer('message', 'stream', 'main', '', '', 'replacement')
	before := state.buffer_snapshot('message') or { panic('missing') }
	state.mu.@lock()
	assert !state.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', '', 'stale-producer')
	state.mu.unlock()
	state.finish_initial_send(claim)
	after := state.buffer_snapshot('message') or { panic('missing') }
	assert after.generation == before.generation
	assert after.content == 'replacement'
}
