module conversation_binding

fn test_release_is_scoped_to_channel_and_generation() {
	release := Release{platform: 'wecom', generation: 'old', message_ids: ['same']}
	assert release.owns(ReplyTarget{platform: 'wecom', stream_generation: 'old', message_id: 'same'})
	assert !release.owns(ReplyTarget{platform: 'feishu', stream_generation: 'old', message_id: 'same'})
	assert !release.owns(ReplyTarget{platform: 'wecom', stream_generation: 'new', message_id: 'same'})
}
