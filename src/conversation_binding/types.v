module conversation_binding

pub struct ReplyTarget {
pub:
	stream_generation string
	buffer_message_id string
	platform string
	message_id string
}

pub struct Release {
pub:
	platform string
	generation string
	stream_id string
	message_ids []string
	retire_route bool
}

pub fn (release Release) owns(target ReplyTarget) bool {
	if release.platform == '' || target.platform != release.platform { return false }
	if target.stream_generation == '' { return target.message_id in release.message_ids }
	return target.stream_generation == release.generation
		&& (target.buffer_message_id in release.message_ids || target.message_id in release.message_ids)
}
