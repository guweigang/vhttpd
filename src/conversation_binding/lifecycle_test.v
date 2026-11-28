module conversation_binding

fn test_rebinding_preserves_other_channels_and_release_generations() {
	mut routes := map[string][]ReplyTarget{}
	rebind(mut routes, 'old', ReplyTarget{platform: 'feishu', message_id: 'same', stream_generation: '1'})
	rebind(mut routes, 'old', ReplyTarget{platform: 'custom', message_id: 'same', stream_generation: '1'})
	rebind(mut routes, 'new', ReplyTarget{platform: 'custom', message_id: 'same', stream_generation: '2'})
	assert routes['old'].len == 1
	assert routes['old'][0].platform == 'feishu'
	assert retain_after_release(routes['new'], Release{platform: 'custom', generation: '1', message_ids: ['same']}).len == 1
	assert retain_after_release(routes['new'], Release{platform: 'custom', generation: '2', message_ids: ['same']}).len == 0
}
