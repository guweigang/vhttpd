module conversation_binding

pub fn retain_after_release(targets []ReplyTarget, release Release) []ReplyTarget {
	mut retained := []ReplyTarget{}
	for target in targets {
		if !release.owns(target) { retained << target }
	}
	return retained
}

pub fn rebind(mut routes map[string][]ReplyTarget, stream string, target ReplyTarget) {
	if stream == '' || target.platform == '' || target.message_id == '' { return }
	for key, targets in routes {
		mut retained := []ReplyTarget{}
		for existing in targets {
			if existing.platform != target.platform || existing.message_id != target.message_id {
				retained << existing
			}
		}
		if retained.len == 0 { routes.delete(key) } else { routes[key] = retained }
	}
	routes[stream] << target
}
