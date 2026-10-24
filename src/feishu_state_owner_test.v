module main

import feishu

fn test_feishu_ensure_returns_owned_event_snapshot() {
	mut state := feishu.FeishuState{}
	state.push_event('main', feishu.RuntimeEventSnapshot{ event_id: 'original' })
	mut held := state.ensure('main')
	held.recent_events[0] = feishu.RuntimeEventSnapshot{ event_id: 'changed' }
	assert state.ensure('main').recent_events[0].event_id == 'original'
}

fn test_feishu_update_runtime_copies_event_input() {
	mut state := feishu.FeishuState{}
	mut replacement := feishu.ProviderRuntime.new('main')
	replacement.push_event(feishu.RuntimeEventSnapshot{ event_id: 'original' }, 20)
	state.update_runtime('main', replacement)
	replacement.recent_events[0] = feishu.RuntimeEventSnapshot{ event_id: 'changed' }
	assert state.ensure('main').recent_events[0].event_id == 'original'
}

fn test_feishu_concurrent_runtime_updates_preserve_counters_and_events() {
	mut state := &feishu.FeishuState{ recent_event_limit: 2048 }
	mut workers := []thread{}
	for worker in 0 .. 16 {
		workers << spawn fn [mut state, worker] () {
			for iteration in 0 .. 64 {
				state.note_connecting('main')
				state.note_connected('main', 'wss://example.invalid')
				state.note_frame('main')
				state.note_ack('main')
				state.note_send('main', true)
				state.note_send('main', false)
				state.push_event('main', feishu.RuntimeEventSnapshot{ event_id: '${worker}:${iteration}' })
			}
		}()
	}
	workers.wait()
	live := state.ensure('main')
	assert live.connect_attempts == 1024
	assert live.connect_successes == 1024
	assert live.received_frames == 1024
	assert live.acked_events == 1024
	assert live.messages_sent == 1024
	assert live.send_errors == 1024
	assert live.recent_events.len == 1024
	mut ids := map[string]bool{}
	for event in live.recent_events { ids[event.event_id] = true }
	assert ids.len == 1024
}

fn test_feishu_concurrent_token_and_config_updates_preserve_activity() {
	mut state := &feishu.FeishuState{}
	mut workers := []thread{}
	for worker in 0 .. 8 {
		workers << spawn fn [mut state, worker] () {
			for iteration in 0 .. 128 {
				if worker == 0 {
					state.cache_tenant_access_token('main', 'token-${iteration}', 10000 + iteration)
				} else if worker == 1 {
					state.note_client_config('main', feishu.RuntimeClientConfig{ ping_interval: iteration + 1 })
				} else {
					state.note_frame('main')
				}
			}
		}()
	}
	workers.wait()
	live := state.ensure('main')
	assert live.received_frames == 768
	assert live.tenant_access_token == 'token-127'
	assert live.tenant_access_token_expire_unix == 10127
	assert state.ping_interval_seconds('main') == 128
}

fn test_feishu_event_retention_and_lifecycle_preserve_other_apps_and_held_snapshot() {
	mut state := feishu.FeishuState{ recent_event_limit: 2 }
	assert state.ensure('main').name == 'main'
	assert state.ping_interval_seconds('main') == 5
	state.cache_tenant_access_token('main', 'token', 10000)
	state.note_connected('main', 'wss://example.invalid')
	state.push_event('main', feishu.RuntimeEventSnapshot{ event_id: 'first' })
	held := state.ensure('main')
	state.push_event('main', feishu.RuntimeEventSnapshot{ event_id: 'second' })
	state.push_event('main', feishu.RuntimeEventSnapshot{ event_id: 'third' })
	state.note_disconnected('main', 'closed')
	state.note_client_config('main', feishu.RuntimeClientConfig{ ping_interval: -1 })
	state.note_send('secondary', true)
	live := state.ensure('main')
	assert !live.connected
	assert live.last_error == 'closed'
	assert live.tenant_access_token == 'token'
	assert live.recent_events.map(it.event_id) == ['second', 'third']
	assert held.connected
	assert held.recent_events.map(it.event_id) == ['first']
	assert state.runtime_ws_url('main') == 'wss://example.invalid'
	assert state.ping_interval_seconds('main') == 5
	assert state.ensure('secondary').messages_sent == 1
	assert state.ensure('secondary').recent_events.len == 0
	assert live.messages_sent == 0
}
