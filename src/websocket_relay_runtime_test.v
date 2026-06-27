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
