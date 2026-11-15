module conversation_binding

import time

pub const session_limit = 1024
pub const targets_per_session = 128
pub const session_ttl_ms = i64(30 * 60 * 1000)

pub struct SessionManager[T] {
pub mut:
	stream_map map[string][]T
	deadlines map[string]i64
}

pub fn (mut routes SessionManager[T]) prune_expired(now i64) []string {
	mut expired := []string{}
	for stream, deadline in routes.deadlines {
		if deadline <= now {
			routes.clear_stream(stream)
			expired << stream
		}
	}
	return expired
}

pub fn (routes &SessionManager[T]) streams() []string {
	return routes.stream_map.keys()
}

pub fn (routes &SessionManager[T]) contains(stream string) bool {
	return stream in routes.stream_map
}

pub fn (mut routes SessionManager[T]) touch(stream string) {
	if routes.contains(stream) { routes.deadlines[stream] = time.now().unix_milli() + session_ttl_ms }
}

pub fn (mut routes SessionManager[T]) rebind(stream string, target T) {
	if stream == '' || target.platform == '' || target.message_id == '' { return }
	if stream.len > 4096 || target.message_id.len + target.platform.len
		+ target.stream_generation.len + target.buffer_message_id.len > 4096 { return }
	if !routes.contains(stream) && routes.stream_map.len >= session_limit { return }
	if routes.stream_map[stream].len >= targets_per_session { return }
	for previous in routes.streams() {
		routes.remove_stream_target(previous, target.platform, target.message_id)
	}
	routes.add_stream_target(stream, target)
}

pub fn (mut routes SessionManager[T]) release_targets(release Release) {
	mut retained := []T{}
	for target in routes.stream_targets(release.stream_id) {
		if !release.owns(target) { retained << target }
	}
	if retained.len == 0 {
		routes.clear_stream(release.stream_id)
	} else {
		routes.stream_map[release.stream_id] = retained
	}
}

pub fn (mut routes SessionManager[T]) add_stream_target(stream string, target T) bool {
	if stream == '' || stream.len > 4096 || target.message_id.len + target.platform.len
		+ target.stream_generation.len + target.buffer_message_id.len > 4096 { return false }
	if stream !in routes.stream_map && routes.stream_map.len >= session_limit { return false }
	if routes.stream_map[stream].len >= targets_per_session { return false }
	routes.stream_map[stream] << target
	routes.deadlines[stream] = time.now().unix_milli() + session_ttl_ms
	return true
}

pub fn (routes &SessionManager[T]) stream_targets(stream string) []T {
	return routes.stream_map[stream].clone()
}

pub fn (routes &SessionManager[T]) snapshot() &SessionManager[T] {
	mut targets := map[string][]T{}
	for stream, entries in routes.stream_map { targets[stream] = entries.clone() }
	return &SessionManager[T]{stream_map: targets, deadlines: routes.deadlines.clone()}
}

pub fn (mut routes SessionManager[T]) clear_stream(stream string) bool {
	routes.deadlines.delete(stream)
	if stream !in routes.stream_map { return false }
	routes.stream_map.delete(stream)
	return true
}

pub fn (mut routes SessionManager[T]) remove_stream_target(stream string, platform string, message string) bool {
	if stream == '' { return false }
	previous := routes.stream_map[stream] or { return false }
	mut retained := []T{}
	for target in previous {
		if (message != '' && target.message_id != message) || (platform != '' && target.platform != platform) {
			retained << target
		}
	}
	if retained.len == previous.len { return false }
	if retained.len == 0 { routes.clear_stream(stream) } else { routes.stream_map[stream] = retained }
	return true
}
