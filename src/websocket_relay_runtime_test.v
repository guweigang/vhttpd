module main

import relay
import runtime_plan

fn test_relay_websocket_path_descriptor_matches_explicit_hub_path() {
	mut app := App{}
	app.relay = relay.new_runtime(runtime_plan.RuntimePlan{
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
						'path':    '/vhttpd/relay'
						'node_id': 'hub_1'
					}
				}
			}
		}
	}) or { panic(err) }

	descriptor := relay_websocket_path_descriptor(app, '/vhttpd/relay?token=ignored') or {
		panic('missing relay')
	}
	missing := relay_websocket_path_descriptor(app, '/ordinary/ws')

	assert descriptor.id == 'edge'
	assert missing == none
}

fn test_relay_websocket_event_fields_add_request_context() {
	mut state := &RelayWebSocketBridgeState{
		descriptor: relay.RelayDescriptor{
			id: 'edge'
		}
		conn_id:    'carrier_1'
		path:       '/vhttpd/relay'
		request_id: 'req_1'
		trace_id:   'trace_1'
	}

	fields := relay_websocket_event_fields({
		'relay_event': 'inbound.registered'
		'frame_id':    'frm_1'
	}, state)

	assert fields['relay_event'] == 'inbound.registered'
	assert fields['trace_id'] == 'trace_1'
	assert fields['request_id'] == 'req_1'
	assert fields['path'] == '/vhttpd/relay'
	assert fields['relay_id'] == 'edge'
	assert fields['carrier_id'] == 'carrier_1'
	assert fields['frame_id'] == 'frm_1'
}
