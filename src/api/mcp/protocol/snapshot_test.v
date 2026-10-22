module protocol

import net
import time

fn snapshot_settings(label string) Settings {
	return if label == 'a' {
		Settings{
			max_sessions:               17
			max_pending_messages:       7
			session_ttl_seconds:        37
			allowed_origins:            ['https://a.test']
			sampling_capability_policy: 'warn'
		}
	} else {
		Settings{
			max_sessions:               31
			max_pending_messages:       11
			session_ttl_seconds:        73
			allowed_origins:            ['https://b.test', 'https://other.test']
			sampling_capability_policy: 'drop'
		}
	}
}

fn test_retained_mcp_snapshot_keeps_original_settings_rows_and_pagination() {
	mut owner := snapshot_settings('a').new_state()
	owner.ensure_session('old', 'old-version', 'old-request', 'old-trace', '/mcp')
	assert owner.do_queue('old', 'message').queued
	view := owner.snapshot_view('', '')
	owner.apply_settings(snapshot_settings('b'))
	assert owner.delete_session('old')
	owner.ensure_session('new', 'new-version', '', '', '/mcp')
	for details in [true, false] {
		page := view.page(details, 10, 0)
		assert page.max_sessions == 17
		assert page.max_pending_messages == 7
		assert page.session_ttl_seconds == 37
		assert page.allowed_origins == ['https://a.test']
		assert page.sampling_capability_policy == 'warn'
		assert page.active_sessions == 1
		if details {
			assert page.sessions[0].id == 'old'
			assert page.sessions[0].pending_count == 1
			assert page.sessions[0].trace_id == 'old-trace'
		} else {
			assert page.sessions.len == 0
		}
	}
	current := owner.snapshot(true, 10, 0, '', '')
	assert current.max_sessions == 31
	assert current.sessions[0].id == 'new'
}

fn snapshot_check_publication(snapshot RuntimeSnapshot) {
	if snapshot.max_sessions == 17 {
		assert snapshot.max_pending_messages == 7
		assert snapshot.session_ttl_seconds == 37
		assert snapshot.allowed_origins == ['https://a.test']
		assert snapshot.sampling_capability_policy == 'warn'
	} else {
		assert snapshot.max_sessions == 31
		assert snapshot.max_pending_messages == 11
		assert snapshot.session_ttl_seconds == 73
		assert snapshot.allowed_origins == ['https://b.test', 'https://other.test']
		assert snapshot.sampling_capability_policy == 'drop'
	}
}

fn test_concurrent_mcp_reload_and_snapshot_never_mix_configuration_fields() {
	mut owner := &McpState{}
	owner.apply_settings(snapshot_settings('a'))
	owner.ensure_session('session', 'version', '', '', '/mcp')
	done := chan bool{cap: 1}
	spawn fn [mut owner, done] () {
		for _ in 0 .. 1500 {
			owner.apply_settings(snapshot_settings('b'))
			owner.apply_settings(snapshot_settings('a'))
		}
		done <- true
	}()
	for i in 0 .. 1500 {
		details := i % 2 == 0
		snapshot := owner.snapshot(details, 10, 0, '', '')
		snapshot_check_publication(snapshot)
		assert snapshot.active_sessions == 1
		assert snapshot.returned_sessions == if details { 1 } else { 0 }
	}
	_ := <-done
}

fn test_snapshot_expiration_uses_captured_ttl_and_keeps_native_close_owner() {
	mut owner := McpState{ session_ttl_seconds: 1 }
	owner.ensure_session('expired', 'version', '', '', '/mcp')
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	defer { peer.close() or {} }
	conn := listener.accept() or { panic(err) }
	mut stream := owner.attach_stream('expired', conn) or { panic(err) }
	defer { owner.finish_stream('expired', mut stream) }
	owner.mu.@lock()
	mut session := owner.sessions['expired']
	session.last_activity_unix = time.now().unix() - 10
	owner.sessions['expired'] = session
	owner.mu.unlock()
	view := owner.snapshot_view('', '')
	assert stream.stopped()
	assert !stream.finished()
	assert owner.active_streams() == 1
	owner.apply_settings(snapshot_settings('b'))
	page := view.page(true, 10, 0)
	assert page.session_ttl_seconds == 1
	assert page.active_sessions == 0
	assert page.sessions.len == 0
	assert owner.stat_sessions_expired_total == 1
	owner.finish_stream('expired', mut stream)
	assert stream.finished()
	assert owner.active_streams() == 0
}

fn test_snapshot_pages_handle_negative_and_extreme_bounds_without_overflow() {
	mut owner := McpState{}
	for i in 0 .. 3 { owner.ensure_session('s${i}', 'version', '', '', '/mcp') }
	for details in [true, false] {
		for bounds in [[-1, -1], [2147483647, 2147483647], [2147483647, 1], [0, 0]] {
			page := owner.snapshot(details, bounds[0], bounds[1], '', '')
			assert page.active_sessions == 3
			assert page.limit >= 0
			assert page.offset >= 0
			expected := if details && bounds[1] == 1 { 2 } else { 0 }
			assert page.returned_sessions == expected
			assert page.sessions.len == expected
		}
	}
}

fn test_snapshot_preserves_defaults_filters_and_detached_ordering() {
	mut owner := McpState{}
	for i in 0 .. 3 {
		owner.ensure_session('s${i}', if i == 2 { 'other' } else { 'version' }, '', '', '/mcp')
		owner.mu.@lock()
		mut session := owner.sessions['s${i}']
		session.started_at_unix = 100 + i
		owner.sessions['s${i}'] = session
		owner.mu.unlock()
	}
	view := owner.snapshot_view('', 'version')
	page := view.page(true, 1, 1)
	assert page.max_sessions == 1000
	assert page.max_pending_messages == 128
	assert page.session_ttl_seconds == 900
	assert page.sampling_capability_policy == 'warn'
	assert page.active_sessions == 2
	assert page.returned_sessions == 1
	assert page.sessions[0].id == 's1'
	assert view.sessions.len == 2
	assert view.page(true, 10, 0).sessions[0].id == 's0'
	filtered := owner.snapshot(true, 10, 0, 's2', 'other')
	assert filtered.session_id == 's2'
	assert filtered.protocol_version == 'other'
	assert filtered.active_sessions == 1
	assert filtered.sessions[0].id == 's2'
}
