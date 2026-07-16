module main

import config
import os
import plugin
import provider
import runtime_plan

fn test_provider_action_adapter_helpers_apply_defaults_and_overrides() {
	default_adapter := runtime_plan.AdapterPlan{
		id:      'provider-send'
		kind:    'provider-action'
		options: runtime_plan.PlanOptions{}
	}
	override_adapter := runtime_plan.AdapterPlan{
		id:      'provider-send'
		kind:    'provider-action'
		options: runtime_plan.PlanOptions{
			strings: {
				'payload':      '{"configured":true}'
				'content_type': 'application/vnd.vhttpd+json'
			}
			ints:    {
				'status': 202
			}
		}
	}

	assert provider_action_payload(default_adapter, '{"fallback":true}') == '{"fallback":true}'
	assert provider_action_response_status(default_adapter) == 200
	assert provider_action_response_content_type(default_adapter) == 'application/json'
	assert provider_action_payload(override_adapter, '{"fallback":true}') == '{"configured":true}'
	assert provider_action_response_status(override_adapter) == 202
	assert provider_action_response_content_type(override_adapter) == 'application/vnd.vhttpd+json'
}

fn test_provider_action_adapter_dispatches_configured_vjsx_runtime_override() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_action_override_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'provider-action.mts')
	os.write_file(plugin_file, '
export function plugin(req) {
  return {
    ok: true,
    source: "adapter-runtime",
    capability: req.capability,
    provider: req.metadata.provider,
    action: req.metadata.action,
    adapter: req.metadata.adapter_id,
  };
}
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'adapter-provider-runtime': config.PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
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
	adapter := runtime_plan.AdapterPlan{
		id:      'provider-send'
		kind:    'provider-action'
		options: runtime_plan.PlanOptions{
			strings: {
				'provider':       'feishu'
				'action':         'send_message'
				'runtime_driver': 'vjsx'
				'runtime_plugin': 'adapter-provider-runtime'
				'capability':     'feishu.message.send'
			}
		}
	}

	resp := app.dispatch_provider_action_adapter(adapter, 'provider-send', '{"receive_id":"chat"}',
		'req-1', 'trace-1', {
		'pipeline_id': 'provider/action'
	})

	assert resp.ok
	assert resp.result.contains('"source":"adapter-runtime"')
	assert resp.result.contains('"capability":"feishu.message.send"')
	assert resp.result.contains('"adapter":"provider-send"')
}

fn test_provider_action_adapter_uses_provider_runtime_capability_when_not_overridden() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_action_capability_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'provider-action.mts')
	os.write_file(plugin_file, '
export function plugin(req) {
  return {
    ok: true,
    capability: req.capability,
    provider: req.metadata.provider,
    action: req.metadata.action,
  };
}
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'provider-runtime': config.PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		providers: ProviderRuntimeHub.new(provider.ProviderRuntimeSettings{
			runtime_drivers: {
				'feishu': 'vjsx'
			}
			runtime_plugins: {
				'feishu': 'provider-runtime'
			}
			runtime_capabilities: {
				'feishu': {
					'send_message': 'feishu.message.send.from.provider'
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
	adapter := runtime_plan.AdapterPlan{
		id:      'provider-send'
		kind:    'provider-action'
		options: runtime_plan.PlanOptions{
			strings: {
				'provider': 'feishu'
				'action':   'send_message'
			}
		}
	}

	resp := app.dispatch_provider_action_adapter(adapter, 'provider-send', '{"receive_id":"chat"}',
		'req-1', 'trace-1', {
		'pipeline_id': 'provider/action'
	})

	assert resp.ok
	assert resp.result.contains('"capability":"feishu.message.send.from.provider"')
}
