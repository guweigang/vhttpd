module conversation_binding

fn test_manager_capacity_expiry_and_snapshot_deadlines() {
	mut manager := SessionManager[ReplyTarget]{}
	for index in 0 .. targets_per_session {
		assert manager.add_stream_target('stream', ReplyTarget{platform: 'custom', message_id: index.str()})
	}
	assert !manager.add_stream_target('stream', ReplyTarget{message_id: 'overflow'})
	mut snapshot := manager.snapshot()
	deadline := manager.deadlines['stream']
	assert manager.prune_expired(deadline - 1).len == 0
	assert manager.prune_expired(deadline).len == 1
	assert manager.stream_map.len == 0
	assert manager.deadlines.len == 0
	assert snapshot.contains('stream')
}

fn test_manager_global_capacity_and_touch() {
	mut manager := SessionManager[ReplyTarget]{}
	for index in 0 .. session_limit {
		assert manager.add_stream_target(index.str(), ReplyTarget{platform: 'custom', message_id: 'reply'})
	}
	assert !manager.add_stream_target('extra', ReplyTarget{platform: 'custom', message_id: 'reply'})
	manager.deadlines['0'] = 1
	manager.touch('0')
	assert manager.prune_expired(2).len == 0
	assert manager.stream_map.len == session_limit
}
