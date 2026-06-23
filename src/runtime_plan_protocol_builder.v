module main

import api.mcp.protocol as mcp_protocol
import api.openai
import config
import runtime_plan
import state_store

fn mcp_state_from_plan(plan runtime_plan.RuntimePlan, listener_id string) mcp_protocol.McpState {
	adapter := plan.listener_adapter(listener_id, 'mcp') or {
		return mcp_protocol.McpState{
			max_sessions:               1000
			max_pending_messages:       128
			session_ttl_seconds:        900
			sampling_capability_policy: 'warn'
			sessions:                   map[string]mcp_protocol.Session{}
		}
	}
	return mcp_protocol.McpState{
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
		sessions:                   map[string]mcp_protocol.Session{}
	}
}

fn openai_state_from_plan(plan runtime_plan.RuntimePlan, listener_id string) openai.OpenaiState {
	adapter := plan.listener_adapter(listener_id, 'openai') or {
		return openai.OpenaiState{
			responses: state_store.MemoryStateStore.new[openai.OpenAIResponseRecord]()
		}
	}
	return openai.OpenaiState{
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
		responses:       state_store.MemoryStateStore.new[openai.OpenAIResponseRecord]()
	}
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
		configs[name] = config.PluginConfig{
			kind:              transform.kind
			entry:             engine.options.strings['entry']
			app_entry:         engine.options.strings['entry']
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
	return configs
}
