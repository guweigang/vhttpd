module ws

import time

// ── Fixture Runtime Management ──

pub fn (mut h HubState) fixture_ensure(name string) FixtureRuntime {
	h.upstream_mu.@lock()
	defer {
		h.upstream_mu.unlock()
	}
	if name in h.fixture_runtime {
		return h.fixture_runtime[name]
	}
	runtime := FixtureRuntime{
		name:                 name
		connected:            true
		last_connect_at_unix: time.now().unix()
		connect_attempts:     1
		connect_successes:    1
	}
	h.fixture_runtime[name] = runtime
	return runtime
}

pub fn (mut h HubState) fixture_update(name string, runtime FixtureRuntime) {
	h.upstream_mu.@lock()
	defer {
		h.upstream_mu.unlock()
	}
	h.fixture_runtime[name] = runtime
}

pub fn (mut h HubState) fixture_app_names() []string {
	h.upstream_mu.@lock()
	defer {
		h.upstream_mu.unlock()
	}
	mut names := h.fixture_runtime.keys()
	names.sort()
	return names
}

pub fn (mut h HubState) fixture_snapshot(name string) UpstreamSnapshot {
	runtime := h.fixture_ensure(name)
	return UpstreamSnapshot{
		provider:                'fixture'
		instance:                runtime.name
		enabled:                 true
		configured:              true
		connected:               runtime.connected
		url:                     'fixture://${runtime.name}'
		last_connect_at_unix:    runtime.last_connect_at_unix
		last_disconnect_at_unix: runtime.last_disconnect_at_unix
		last_error:              runtime.last_error
		connect_attempts:        runtime.connect_attempts
		connect_successes:       runtime.connect_successes
		received_frames:         runtime.received_frames
	}
}

pub fn (mut h HubState) fixture_note_send(instance string, ok bool) {
	mut runtime := h.fixture_ensure(instance)
	if ok {
		runtime.messages_sent++
	} else {
		runtime.send_errors++
	}
	h.fixture_update(instance, runtime)
}

pub fn (mut h HubState) fixture_send(instance string) UpstreamSendResult {
	name := if instance.trim_space() == '' { 'main' } else { instance.trim_space() }
	h.fixture_note_send(name, true)
	return UpstreamSendResult{
		ok:         true
		provider:   'fixture'
		instance:   name
		message_id: 'fixture-msg-${time.now().unix_micro()}'
	}
}

pub fn (mut h HubState) fixture_update_msg(instance string, target string) !UpstreamUpdateResult {
	name := if instance.trim_space() == '' { 'main' } else { instance.trim_space() }
	t := target.trim_space()
	if t == '' {
		return error('missing fixture update target')
	}
	h.fixture_note_send(name, true)
	return UpstreamUpdateResult{
		ok:         true
		provider:   'fixture'
		instance:   name
		message_id: t
	}
}

// ── Activity Recording ──

pub fn (mut h HubState) record_upstream_activity(snapshot UpstreamActivitySnapshot) {
	h.upstream_mu.@lock()
	defer {
		h.upstream_mu.unlock()
	}
	limit := if h.recent_dispatch_limit > 0 {
		h.recent_dispatch_limit
	} else {
		50
	}
	h.recent_activities << snapshot
	if h.recent_activities.len > limit {
		start := h.recent_activities.len - limit
		h.recent_activities = h.recent_activities[start..].clone()
	}
}

pub fn (mut h HubState) upstream_activities_snapshot(limit int, offset int, provider_filter string, instance_filter string) UpstreamActivityListSnapshot {
	h.upstream_mu.@lock()
	defer {
		h.upstream_mu.unlock()
	}
	mut activities := []UpstreamActivitySnapshot{}
	for entry in h.recent_activities {
		if provider_filter != '' && entry.provider != provider_filter {
			continue
		}
		if instance_filter != '' && entry.instance != instance_filter {
			continue
		}
		activities << entry
	}
	activities.sort(a.received_at > b.received_at)
	if offset >= activities.len {
		return UpstreamActivityListSnapshot{
			returned_count: 0
			limit:          limit
			offset:         offset
			activities:     []UpstreamActivitySnapshot{}
		}
	}
	end := if offset + limit < activities.len { offset + limit } else { activities.len }
	return UpstreamActivityListSnapshot{
		returned_count: end - offset
		limit:          limit
		offset:         offset
		activities:     activities[offset..end].clone()
	}
}
