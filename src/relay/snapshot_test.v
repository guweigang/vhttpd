module relay

import runtime_plan

fn test_runtime_snapshot_summarizes_relay_state_and_trace_ids() {
	descriptor := descriptor_from_plan(runtime_plan.RelayPlan{
		id:   'local'
		mode: 'agent'
		options: runtime_plan.PlanOptions{
			strings: {
				'url':     'wss://relay.example.com'
				'node_id': 'local-dev'
			}
		}
	}) or { panic(err) }
	mut channels := new_channel_registry(4)
	channels.open_channel(RelayChannel{
		id:       'chan_1'
		node_id:  'local-dev'
		route:    'site/main'
		trace_id: 'trace_1'
	}) or { panic(err) }
	channels.enqueue('chan_1', new_frame(.data, 'frm_1', 'trace_1')) or { panic(err) }
	mut sessions := new_session_registry()
	sessions.buffer_pending('session_1', 'link_1', new_frame(.data, 'frm_2', 'trace_2'),
		4) or { panic(err) }

	snapshot := runtime_snapshot({
		'local': descriptor
	}, [new_agent_state(descriptor).mark_failed(100, 'dial_failed', AgentReconnectPolicy{
		initial_delay_ms: 50
		max_delay_ms:     500
	})], channels, sessions)

	assert snapshot.descriptor_count == 1
	assert snapshot.agent_count == 1
	assert snapshot.channel_count == 1
	assert snapshot.open_channels == 1
	assert snapshot.session_count == 1
	assert snapshot.pending_frames == 2
	assert snapshot.agents[0].state == 'backoff'
	assert snapshot.agents[0].last_error == 'dial_failed'
	assert snapshot.channels[0].trace_id == 'trace_1'
	assert snapshot.channels[0].buffered_len == 1
	assert snapshot.sessions[0].pending_frames == 1
}

fn test_runtime_snapshot_orders_channels_and_sessions_by_id() {
	mut channels := new_channel_registry(4)
	channels.open_channel(RelayChannel{
		id:       'b'
		trace_id: 'trace_b'
	}) or { panic(err) }
	channels.open_channel(RelayChannel{
		id:       'a'
		trace_id: 'trace_a'
	}) or { panic(err) }
	mut sessions := new_session_registry()
	sessions.buffer_pending('b', 'link', new_frame(.data, 'frm_b', 'trace_b'), 4) or { panic(err) }
	sessions.buffer_pending('a', 'link', new_frame(.data, 'frm_a', 'trace_a'), 4) or { panic(err) }

	snapshot := runtime_snapshot(map[string]RelayDescriptor{}, []AgentState{}, channels, sessions)

	assert snapshot.channels.map(it.id) == ['a', 'b']
	assert snapshot.sessions.map(it.id) == ['a', 'b']
}
