module main

import api.mcp.protocol as mcp_protocol
import api.openai
import config
import json2 as json
import plugin
import runtime_plan

struct ProtocolRuntimePlanUpdate {
	runtime_plan_json string
	plugin_configs    map[string]config.PluginConfig
	mcp               mcp_protocol.Settings
	openai            openai.Settings
}

fn ProtocolRuntimeHub.from_plan(cfg config.VhttpdConfig, plan runtime_plan.RuntimePlan, listener_id string) ProtocolRuntimeHub {
	plugin_configs := plugin_configs_from_plan(plan)
	update := protocol_runtime_plan_update_from_plan(plan, listener_id)
	return ProtocolRuntimeHub{
		runtime_config_json: json.encode(cfg, escape_unicode: true, time_as_unix: true)
		runtime_plan_json:   update.runtime_plan_json
		plugins:             plugin.PluginState{
			configs: plugin_configs.clone()
			vjsx:    build_vjsx_plugin_runtimes(plugin_configs)
		}
		mcp:                 update.mcp.new_state()
		openai:              update.openai.new_state()
	}
}

fn protocol_runtime_plan_update_from_plan(plan runtime_plan.RuntimePlan, listener_id string) ProtocolRuntimePlanUpdate {
	return ProtocolRuntimePlanUpdate{
		runtime_plan_json: json.encode(plan, escape_unicode: true, time_as_unix: true)
		plugin_configs:    plugin_configs_from_plan(plan)
		mcp:               mcp_settings_from_plan(plan, listener_id)
		openai:            openai_settings_from_plan(plan, listener_id)
	}
}

fn (mut hub ProtocolRuntimeHub) apply_plan_update(update ProtocolRuntimePlanUpdate) {
	retirement := hub.publish_plan_update(update)
	hub.plugins.finish_retirement(retirement)
}

// Publication never waits for plugin calls. The caller drains the retired batch
// after releasing App.mu, which an active plugin's host callbacks may need.
fn (mut hub ProtocolRuntimeHub) publish_plan_update(update ProtocolRuntimePlanUpdate) int {
	hub.runtime_plan_json = update.runtime_plan_json
	retirement := hub.plugins.publish(update.plugin_configs)
	hub.mcp.apply_settings(update.mcp)
	hub.openai.apply_settings(update.openai)
	return retirement
}

fn mcp_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string) mcp_protocol.Settings {
	adapter := plan.listener_adapter(listener_id, 'mcp') or {
		return mcp_protocol.Settings{
			max_sessions:               1000
			max_pending_messages:       128
			session_ttl_seconds:        900
			sampling_capability_policy: 'warn'
		}
	}
	return mcp_protocol.Settings{
		max_sessions:               if adapter.options.ints['max_sessions'] > 0 {
			adapter.options.ints['max_sessions']
		} else {
			1000
		}
		max_pending_messages:       if adapter.options.ints['max_pending_messages'] > 0 {
			adapter.options.ints['max_pending_messages']
		} else {
			128
		}
		session_ttl_seconds:        if adapter.options.ints['session_ttl_seconds'] > 0 {
			adapter.options.ints['session_ttl_seconds']
		} else {
			900
		}
		sampling_capability_policy: mcp_protocol.McpState.normalize_sampling_capability_policy(adapter.options.strings['sampling_capability_policy'])
		allowed_origins:            adapter.options.string_lists['allowed_origins'].clone()
	}
}

fn openai_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string) openai.Settings {
	adapter := plan.listener_adapter(listener_id, 'openai') or {
		return openai.Settings{}
	}
	return openai.Settings{
		enabled:         true
		base_path:       if adapter.options.strings['base_path'] != '' {
			adapter.options.strings['base_path']
		} else {
			'/v1'
		}
		default_backend: adapter.options.strings['default_backend']
		plugin:          adapter.options.strings['plugin']
		endpoints:       config.OpenAIEndpointsConfig{
			models:           adapter.options.bools['endpoint_models']
			chat_completions: adapter.options.bools['endpoint_chat_completions']
			responses:        adapter.options.bools['endpoint_responses']
			embeddings:       adapter.options.bools['endpoint_embeddings']
		}
		backends:        openai_backends_from_adapter(adapter)
		routes:          openai_routes_from_adapter(adapter)
	}
}

fn protocol_runtime_diagnostics_from_plan(plan runtime_plan.RuntimePlan, listener_id string) []runtime_plan.PlanDiagnostic {
	mut diagnostics := []runtime_plan.PlanDiagnostic{}
	if adapter := plan.listener_adapter(listener_id, 'mcp') {
		diagnostics << mcp_adapter_diagnostics(adapter)
	}
	if adapter := plan.listener_adapter(listener_id, 'openai') {
		diagnostics << openai_adapter_diagnostics(adapter)
	}
	return diagnostics
}

fn mcp_adapter_diagnostics(adapter runtime_plan.AdapterPlan) []runtime_plan.PlanDiagnostic {
	mut diagnostics := []runtime_plan.PlanDiagnostic{}
	policy := adapter.options.strings['sampling_capability_policy'].trim_space()
	if policy != '' && policy.to_lower() !in ['warn', 'drop', 'error'] {
		diagnostics << runtime_plan.PlanDiagnostic{
			severity: 'warning'
			code:     'mcp_sampling_capability_policy_invalid'
			path:     'adapters.${adapter.id}.options.sampling_capability_policy'
			message:  'mcp adapter ${adapter.id} has invalid sampling capability policy ${policy}; falling back to warn'
		}
	}
	return diagnostics
}

fn openai_adapter_diagnostics(adapter runtime_plan.AdapterPlan) []runtime_plan.PlanDiagnostic {
	mut diagnostics := []runtime_plan.PlanDiagnostic{}
	mut backend_ids := map[string]bool{}
	for record in adapter.options.record_lists['backends'] {
		id := record['id'] or {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'error'
				code:     'openai_backend_missing_id'
				path:     'adapters.${adapter.id}.options.backends'
				message:  'openai adapter ${adapter.id} has a backend record without id'
			}
			continue
		}
		if id.trim_space() == '' {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'error'
				code:     'openai_backend_missing_id'
				path:     'adapters.${adapter.id}.options.backends'
				message:  'openai adapter ${adapter.id} has a backend record without id'
			}
			continue
		}
		backend_ids[id] = true
	}
	default_backend := adapter.options.strings['default_backend']
	if default_backend.trim_space() != '' && default_backend !in backend_ids {
		diagnostics << runtime_plan.PlanDiagnostic{
			severity: 'error'
			code:     'openai_default_backend_missing'
			path:     'adapters.${adapter.id}.options.default_backend'
			message:  'openai adapter ${adapter.id} references missing default backend ${default_backend}'
		}
	}
	for record in adapter.options.record_lists['routes'] {
		id := record['id'] or {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'error'
				code:     'openai_route_missing_id'
				path:     'adapters.${adapter.id}.options.routes'
				message:  'openai adapter ${adapter.id} has a route record without id'
			}
			continue
		}
		if id.trim_space() == '' {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'error'
				code:     'openai_route_missing_id'
				path:     'adapters.${adapter.id}.options.routes'
				message:  'openai adapter ${adapter.id} has a route record without id'
			}
			continue
		}
		backend := record['backend']
		if backend.trim_space() != '' && backend !in backend_ids {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'error'
				code:     'openai_route_backend_missing'
				path:     'adapters.${adapter.id}.options.routes.${id}.backend'
				message:  'openai route ${id} references missing backend ${backend}'
			}
		}
	}
	return diagnostics
}

fn openai_backends_from_adapter(adapter runtime_plan.AdapterPlan) map[string]config.OpenAIBackendConfig {
	mut backends := map[string]config.OpenAIBackendConfig{}
	for record in adapter.options.record_lists['backends'] {
		id := record['id'] or { continue }
		backends[id] = config.OpenAIBackendConfig{
			kind:        if record['kind'] != '' { record['kind'] } else { 'openai_http' }
			base_url:    record['base_url']
			executor:    record['executor']
			api_key:     record['api_key']
			api_key_env: if record['api_key_env'] != '' {
				record['api_key_env']
			} else {
				'OPENAI_API_KEY'
			}
			timeout_ms:  record['timeout_ms'].int()
		}
	}
	return backends
}

fn openai_routes_from_adapter(adapter runtime_plan.AdapterPlan) map[string]config.OpenAIRouteConfig {
	mut routes := map[string]config.OpenAIRouteConfig{}
	for record in adapter.options.record_lists['routes'] {
		id := record['id'] or { continue }
		routes[id] = config.OpenAIRouteConfig{
			model:          record['model']
			models:         adapter.options.string_lists[id].clone()
			backend:        record['backend']
			upstream_model: record['upstream_model']
		}
	}
	return routes
}

fn plugin_configs_from_plan(plan runtime_plan.RuntimePlan) map[string]config.PluginConfig {
	mut configs := map[string]config.PluginConfig{}
	mut transform_ids := plan.transforms.keys()
	transform_ids.sort()
	for id in transform_ids {
		transform := plan.transforms[id]
		if !id.contains('/plugin/') {
			continue
		}
		name := id.all_after_last('/')
		engine_ref := transform.engine or { continue }
		engine := plan.engines[engine_ref.id] or { continue }
		configs[name] = plugin_config_from_engine(transform.kind, engine)
	}
	mut provider_ids := plan.providers.keys()
	provider_ids.sort()
	for id in provider_ids {
		provider := plan.providers[id]
		if provider.plugin.trim_space() == '' {
			continue
		}
		engine_ref := provider.engine or { continue }
		engine := plan.engines[engine_ref.id] or { continue }
		kind := if engine.kind.trim_space() != '' { engine.kind } else { provider.driver }
		configs[provider.plugin] = plugin_config_from_engine(kind, engine)
	}
	mut adapter_ids := plan.adapters.keys()
	adapter_ids.sort()
	for id in adapter_ids {
		adapter := plan.adapters[id]
		if adapter.kind != 'provider-action' {
			continue
		}
		plugin_name := adapter.options.strings['runtime_plugin'].trim_space()
		engine_raw := adapter.options.strings['runtime_engine'].trim_space()
		if plugin_name == '' || engine_raw == '' {
			continue
		}
		engine_ref := runtime_plan.parse_ref(engine_raw) or { continue }
		if engine_ref.domain != .engine {
			continue
		}
		engine := plan.engines[engine_ref.id] or { continue }
		driver := adapter.options.strings['runtime_driver']
		kind := if engine.kind.trim_space() != '' { engine.kind } else { driver }
		configs[plugin_name] = plugin_config_from_engine(kind, engine)
	}
	return configs
}

fn plugin_config_from_engine(kind string, engine runtime_plan.EnginePlan) config.PluginConfig {
	entry := engine.options.strings['entry']
	return config.PluginConfig{
		kind:              kind
		entry:             entry
		app_entry:         entry
		module_root:       engine.options.strings['module_root']
		build_root:        engine.options.strings['build_root']
		signature_root:    engine.options.strings['signature_root']
		signature_include: engine.options.string_lists['signature_include'].clone()
		signature_exclude: engine.options.string_lists['signature_exclude'].clone()
		runtime_profile:   engine.options.strings['runtime_profile']
		thread_count:      engine.options.ints['thread_count']
		max_requests:      engine.options.ints['max_requests']
		enable_fs:         engine.options.bools['enable_fs']
		enable_process:    engine.options.bools['enable_process']
		enable_network:    engine.options.bools['enable_network']
	}
}
