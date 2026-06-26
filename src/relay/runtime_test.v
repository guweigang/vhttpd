module relay

import runtime_plan

fn test_runtime_initializes_descriptors_and_channel_limit_from_plan() {
	rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'local': runtime_plan.RelayPlan{
				id:   'local'
				mode: 'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url': 'wss://relay.example.com'
					}
					ints:    {
						'max_channels': 2048
					}
				}
			}
		}
	}) or { panic(err) }

	assert rt.descriptors.len == 1
	assert rt.descriptors['local'].mode == .agent
	assert rt.channels.max_channels == 2048
}

fn test_runtime_tracks_agent_lifecycle() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'local': runtime_plan.RelayPlan{
				id:   'local'
				mode: 'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url': 'wss://relay.example.com'
					}
					ints:    {
						'reconnect_delay_ms': 100
					}
				}
			}
		}
	}) or { panic(err) }

	connecting := rt.mark_agent_connecting('local', 100) or { panic(err) }
	failed := rt.mark_agent_failed('local', 120, 'dial_failed') or { panic(err) }

	assert connecting.state == .connecting
	assert failed.state == .backoff
	assert failed.next_attempt_at_ms == 220
	assert rt.snapshot().agents[0].last_error == 'dial_failed'
}

fn test_runtime_handles_forward_frame_and_session_route() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{}) or { panic(err) }

	forward := rt.handle_frame(WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'node_1', 2)
	route := rt.route_session_frame('session_1', 'link_1', 'ep_client', 'producer',
		new_frame(.data, 'frm_data', 'trace_1'), 2)

	assert forward.action == .opened
	assert route.action == .buffered
	assert rt.snapshot().channel_count == 1
	assert rt.snapshot().session_count == 1
}

fn test_runtime_open_session_endpoint_drains_pending_frames() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{}) or { panic(err) }
	rt.route_session_frame('session_1', 'link_1', 'ep_client', 'producer', new_frame(.data,
		'frm_1', 'trace_1'), 2)

	frames := rt.open_session_endpoint(RelayEndpoint{
		id:         'ep_producer'
		channel_id: 'chan_producer'
		session_id: 'session_1'
		link_id:    'link_1'
		role:       'producer'
		trace_id:   'trace_1'
	}) or { panic(err) }

	assert frames.len == 1
	assert frames[0].id == 'frm_1'
	assert rt.snapshot().pending_frames == 0
}
