module ws

import executor

fn history_event(label string) UpstreamEventSnapshot {
	return UpstreamEventSnapshot{
		message_id: label
		metadata:   {
			'source': label
		}
	}
}

fn history_metadata(values map[string]string) map[string]string { return values }

fn history_commands(values []executor.WebSocketUpstreamCommandActivity) []executor.WebSocketUpstreamCommandActivity {
	return values
}

fn test_fixture_runtime_snapshot_owns_events_and_nested_metadata() {
	mut hub := HubState{}
	hub.fixture_push_event('main', history_event('original'), 20)
	mut held := hub.fixture_ensure('main')
	mut metadata := history_metadata(held.recent_events[0].metadata)
	metadata['source'] = 'changed'
	held.recent_events[0] = history_event('replacement')
	current := hub.fixture_ensure('main')
	assert current.recent_events[0].message_id == 'original'
	assert current.recent_events[0].metadata['source'] == 'original'
}

fn test_fixture_runtime_update_owns_input_events_and_metadata() {
	mut hub := HubState{}
	mut supplied := FixtureRuntime{ name: 'main', recent_events: [history_event('original')] }
	hub.fixture_update('main', supplied)
	mut metadata := history_metadata(supplied.recent_events[0].metadata)
	metadata['source'] = 'changed'
	supplied.recent_events[0] = history_event('replacement')
	current := hub.fixture_ensure('main')
	assert current.recent_events[0].message_id == 'original'
	assert current.recent_events[0].metadata['source'] == 'original'
}

fn test_fixture_event_publication_owns_metadata_and_retains_old_snapshot() {
	mut hub := HubState{}
	mut metadata := {
		'source': 'original'
	}
	hub.fixture_push_event('main', UpstreamEventSnapshot{ message_id: 'first', metadata: metadata }, 2)
	held := hub.fixture_ensure('main')
	mut retained_metadata := history_metadata(metadata)
	retained_metadata['source'] = 'changed'
	hub.fixture_push_event('main', history_event('second'), 2)
	hub.fixture_push_event('main', history_event('third'), 2)
	assert held.recent_events.len == 1
	assert held.recent_events[0].metadata['source'] == 'original'
	current := hub.fixture_ensure('main')
	assert current.received_frames == 3
	assert current.recent_events.map(it.message_id) == ['second', 'third']
}

fn test_fixture_concurrent_events_and_send_counters_are_atomic() {
	mut hub := &HubState{}
	mut workers := []thread{}
	for worker in 0 .. 12 {
		workers << spawn fn [mut hub, worker] () {
			for iteration in 0 .. 64 {
				hub.fixture_note_send('main', true)
				hub.fixture_note_send('main', false)
				hub.fixture_push_event('main', history_event('${worker}:${iteration}'), 1024)
			}
		}()
	}
	workers.wait()
	current := hub.fixture_ensure('main')
	assert current.messages_sent == 768
	assert current.send_errors == 768
	assert current.received_frames == 768
	assert current.recent_events.len == 768
	mut ids := map[string]bool{}
	for event in current.recent_events { ids[event.message_id] = true }
	assert ids.len == 768
}

fn history_activity() UpstreamActivitySnapshot {
	return UpstreamActivitySnapshot{
		provider: 'feishu'
		instance: 'main'
		commands: [executor.WebSocketUpstreamCommandActivity{
			status:         'original'
			metadata:       {
				'source': 'original'
			}
			content_fields: {
				'text': 'original'
			}
		}]
	}
}

fn test_upstream_activity_registry_owns_command_input_and_nested_maps() {
	mut hub := HubState{}
	mut supplied := history_activity()
	hub.record_upstream_activity(supplied)
	mut commands := history_commands(supplied.commands)
	commands[0].status = 'changed'
	mut metadata := history_metadata(commands[0].metadata)
	mut fields := history_metadata(commands[0].content_fields)
	metadata['source'] = 'changed'
	fields['text'] = 'changed'
	current := hub.upstream_activities_snapshot(10, 0, '', '').activities[0]
	assert current.commands[0].status == 'original'
	assert current.commands[0].metadata['source'] == 'original'
	assert current.commands[0].content_fields['text'] == 'original'
}

fn test_upstream_activity_snapshot_owns_commands_and_nested_maps() {
	mut hub := HubState{}
	hub.record_upstream_activity(history_activity())
	mut held := hub.upstream_activities_snapshot(10, 0, 'feishu', 'main').activities[0]
	mut commands := history_commands(held.commands)
	commands[0].status = 'changed'
	mut metadata := history_metadata(commands[0].metadata)
	mut fields := history_metadata(commands[0].content_fields)
	metadata['source'] = 'changed'
	fields['text'] = 'changed'
	current := hub.upstream_activities_snapshot(10, 0, '', '').activities[0]
	assert current.commands[0].status == 'original'
	assert current.commands[0].metadata['source'] == 'original'
	assert current.commands[0].content_fields['text'] == 'original'
}
