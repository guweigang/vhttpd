module relay

import dispatch
import runtime_plan

fn test_runtime_initializes_descriptors_and_channel_limit_from_plan() {
	rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'local': runtime_plan.RelayPlan{
				id:      'local'
				mode:    'agent'
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
				id:      'local'
				mode:    'agent'
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
	route := rt.route_session_frame('session_1', 'link_1', 'ep_client', 'producer', new_frame(.data,
		'frm_data', 'trace_1'), 2)

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

fn test_runtime_tracks_carrier_dispatch_plan() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{}) or { panic(err) }
	frame := new_frame(.data, 'frm_1', 'trace_1')

	missing := rt.carrier_dispatch_plan('relay_1', frame)
	rt.register_carrier('relay_1', 'carrier_1') or { panic(err) }
	ready := rt.carrier_dispatch_plan('relay_1', frame)

	assert !missing.available
	assert missing.error == 'relay_carrier_unavailable:relay_1'
	assert ready.available
	assert ready.carrier_id == 'carrier_1'
}

fn test_runtime_unregisters_carrier_and_returns_to_disabled_plan() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{}) or { panic(err) }
	rt.register_carrier('relay_1', 'carrier_1') or { panic(err) }

	detached := rt.unregister_carrier('relay_1', 'trace_1')
	plan := rt.carrier_dispatch_plan('relay_1', new_frame(.data, 'frm_1', 'trace_1'))

	assert detached.removed
	assert detached.carrier_id == 'carrier_1'
	assert !plan.available
	assert plan.carrier_id == 'disabled:relay_1'
}

fn test_runtime_projects_relay_delivery_through_registered_carrier() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{}) or { panic(err) }
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }

	projection := rt.project_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	assert projection.error == ''
	assert projection.relay_id == 'edge'
	assert projection.frame.trace_id == 'trace_1'
	assert projection.plan.available
	assert projection.plan.carrier_id == 'carrier_edge'
}

fn test_runtime_finds_hub_relay_by_explicit_path() {
	rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'edge':  runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'hub'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'relay'
				}
				options: runtime_plan.PlanOptions{
					strings: {
						'path':    'vhttpd/relay'
						'node_id': 'hub_1'
					}
				}
			}
			'agent': runtime_plan.RelayPlan{
				id:      'agent'
				mode:    'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url': 'wss://relay.example.com'
					}
				}
			}
		}
	}) or { panic(err) }

	descriptor := rt.hub_relay_by_path('/vhttpd/relay') or { panic('missing relay') }
	missing := rt.hub_relay_by_path('/ordinary/ws')

	assert descriptor.id == 'edge'
	assert missing == none
}

fn test_runtime_ignores_hub_relay_without_explicit_path() {
	rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'hub'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'relay'
				}
				options: runtime_plan.PlanOptions{
					strings: {
						'node_id': 'hub_1'
					}
				}
			}
		}
	}) or { panic(err) }

	assert rt.hub_relay_by_path('/vhttpd/relay') == none
}

fn test_runtime_lists_agent_descriptors_in_stable_order() {
	rt := new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'z_agent': runtime_plan.RelayPlan{
				id:      'z_agent'
				mode:    'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url': 'wss://relay-z.example.com'
					}
				}
			}
			'hub':     runtime_plan.RelayPlan{
				id:      'hub'
				mode:    'hub'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'relay'
				}
				options: runtime_plan.PlanOptions{
					strings: {
						'path':    '/vhttpd/relay'
						'node_id': 'hub_1'
					}
				}
			}
			'a_agent': runtime_plan.RelayPlan{
				id:      'a_agent'
				mode:    'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url': 'wss://relay-a.example.com'
					}
				}
			}
		}
	}) or { panic(err) }

	agents := rt.agent_descriptors()

	assert agents.map(it.id) == ['a_agent', 'z_agent']
}
