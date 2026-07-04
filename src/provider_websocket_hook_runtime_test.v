module main

import config
import os
import plugin
import provider
import runtime_plan

fn test_provider_websocket_normalize_hook_dispatches_provider_ingress_event() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_ws_hook_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'provider-ws-hooks.mts')
	os.write_file(plugin_file, "
export function plugin(req) {
  if (req.op !== 'websocket_normalize') {
    return { skip: true };
  }
  const payload = JSON.parse(req.payload);
  const event = JSON.parse(payload.payload);
  return {
    topic: 'provider.feishu',
    name: event.type,
    data: JSON.stringify({ text: event.text }),
    metadata: {
      event_type: event.type,
      instance: payload.instance,
      source: 'vjsx-normalize'
    },
    request_id: req.request_id,
    trace_id: req.trace_id
  };
}
") or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'feishu-ws-hooks': config.PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		plan:      runtime_plan.RuntimePlan{
			providers: {
				'feishu': runtime_plan.ProviderPlan{
					id: 'feishu'
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'provider/feishu-normalized'
					ingress: runtime_plan.ResourceRef{
						domain: .provider
						id:     'feishu'
					}
					match:   runtime_plan.MatchPlan{
						metadata: {
							'event':    'im.message.receive_v1'
							'instance': 'main'
							'source':   'vjsx-normalize'
						}
					}
					egress:  runtime_plan.ResourceRef{
						domain: .terminal
						id:     'ack'
					}
				},
			]
		}
		providers: ProviderRuntimeHub.new(provider.ProviderRuntimeSettings{
			runtime_plugins: {
				'feishu': 'feishu-ws-hooks'
			}
			runtime_options: {
				'feishu': {
					'protocol':         'websocket'
					'normalize_plugin': 'feishu-ws-hooks'
				}
			}
		})
		protocols: ProtocolRuntimeHub{
			plugins: plugin.PluginState{
				configs: plugins
				vjsx:    build_vjsx_plugin_runtimes(plugins)
			}
		}
	}
	defer {
		app.close_all_plugins()
	}

	ok := app.dispatch_provider_websocket_normalized_event('feishu', 'main',
		'wss://provider.test/ws', '{"type":"im.message.receive_v1","text":"hello"}', {
		'transport': 'websocket'
	}, 'req-normalize', 'trace-normalize')

	assert ok
}
