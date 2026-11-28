module conversation_binding

fn test_manager_owns_rebinding_snapshot_and_release_without_engine() {
	mut manager := &SessionManager[ReplyTarget]{}
	manager.add_stream_target('first', ReplyTarget{platform: 'feishu', message_id: 'same', stream_generation: '1'})
	manager.add_stream_target('first', ReplyTarget{platform: 'custom', message_id: 'same', stream_generation: '1'})
	mut held := manager.snapshot()
	manager.rebind('second', ReplyTarget{platform: 'custom', message_id: 'same', stream_generation: '2'})
	assert manager.stream_targets('first').len == 1
	assert held.stream_targets('first').len == 2
	manager.release_targets(Release{platform: 'custom', stream_id: 'second', generation: '1', message_ids: ['same']})
	assert manager.contains('second')
	manager.release_targets(Release{platform: 'custom', stream_id: 'second', generation: '2', message_ids: ['same']})
	assert !manager.contains('second')
	assert held.clear_stream('first')
	assert manager.contains('first')
}
