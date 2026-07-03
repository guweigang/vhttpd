module main

import config
import feishu
import provider
import runtime_plan

fn provider_runtime_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string, fallback provider.ProviderRuntimeSettings) provider.ProviderRuntimeSettings {
	feishu_settings := feishu_runtime_settings_from_plan(plan, listener_id) or { fallback.feishu }
	codex_settings, ollama_enabled := codex_runtime_settings_from_plan(plan, listener_id, fallback)
	runtime_drivers, runtime_plugins := provider_runtime_maps_from_plan(plan, fallback)
	runtime_capabilities := provider_runtime_capability_maps_from_plan(plan, fallback)
	feishu_driver := runtime_drivers['feishu'] or { fallback.feishu.runtime_driver }
	feishu_plugin := runtime_plugins['feishu'] or { fallback.feishu.runtime_plugin }
	return provider.ProviderRuntimeSettings{
		runtime_drivers:      runtime_drivers
		runtime_plugins:      runtime_plugins
		runtime_capabilities: runtime_capabilities
		feishu:               provider.FeishuRuntimeSettings{
			...feishu_settings
			runtime_driver: feishu_driver
			runtime_plugin: feishu_plugin
		}
		codex:          codex_settings
		bridge:         bridge_settings_from_plan(plan, listener_id) or { fallback.bridge }
		db:             fallback.db
		ollama_enabled: ollama_enabled
	}
}

fn provider_runtime_capability_maps_from_plan(plan runtime_plan.RuntimePlan, fallback provider.ProviderRuntimeSettings) map[string]map[string]string {
	mut capabilities := fallback.runtime_capabilities.clone()
	for id, provider_plan in plan.providers {
		if provider_plan.capabilities.len > 0 {
			capabilities[id] = provider_plan.capabilities.clone()
		} else {
			capabilities.delete(id)
		}
	}
	return capabilities
}

fn provider_runtime_maps_from_plan(plan runtime_plan.RuntimePlan, fallback provider.ProviderRuntimeSettings) (map[string]string, map[string]string) {
	mut drivers := fallback.runtime_drivers.clone()
	mut plugins := fallback.runtime_plugins.clone()
	for id, provider_plan in plan.providers {
		driver := provider_plan.driver.trim_space()
		if driver != '' {
			drivers[id] = provider.normalize_runtime_driver(driver)
		}
		plugin := provider_plan.plugin.trim_space()
		if plugin != '' {
			plugins[id] = plugin
		} else {
			plugins.delete(id)
		}
	}
	return drivers, plugins
}

fn feishu_runtime_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string) ?provider.FeishuRuntimeSettings {
	adapter := provider_adapter_for_listener(plan, listener_id, 'feishu-events')?
	return provider.FeishuRuntimeSettings{
		enabled:                    adapter.options.bools['enabled']
		open_base_url:              feishu.RuntimeWsEndpointData.normalize_open_base(adapter.options.strings['open_base_url'])
		reconnect_delay_ms:         if adapter.options.ints['reconnect_delay_ms'] > 0 {
			adapter.options.ints['reconnect_delay_ms']
		} else {
			3000
		}
		token_refresh_skew_seconds: if adapter.options.ints['token_refresh_skew_seconds'] > 0 {
			adapter.options.ints['token_refresh_skew_seconds']
		} else {
			60
		}
		recent_event_limit:         if adapter.options.ints['recent_event_limit'] > 0 {
			adapter.options.ints['recent_event_limit']
		} else {
			20
		}
		apps:                       feishu_apps_from_adapter(adapter)
	}
}

fn feishu_apps_from_adapter(adapter runtime_plan.AdapterPlan) map[string]config.FeishuAppConfig {
	mut apps := map[string]config.FeishuAppConfig{}
	for record in adapter.options.record_lists['apps'] {
		id := record['id']
		if id.trim_space() == '' {
			continue
		}
		apps[id] = config.FeishuAppConfig{
			app_id:             record['app_id']
			app_secret:         record['app_secret']
			verification_token: record['verification_token']
			encrypt_key:        record['encrypt_key']
		}
	}
	return apps
}

fn codex_runtime_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string, fallback provider.ProviderRuntimeSettings) (provider.CodexRuntimeSettings, bool) {
	adapter := provider_adapter_for_listener(plan, listener_id, 'codex') or {
		if openai_adapter := provider_adapter_for_listener(plan, listener_id, 'openai') {
			return fallback.codex, openai_adapter.options.bools['ollama_enabled']
				|| fallback.ollama_enabled
		}
		return fallback.codex, fallback.ollama_enabled
	}
	return provider.CodexRuntimeSettings{
		enabled:            adapter.options.bools['enabled']
		url:                if adapter.options.strings['url'].trim_space() != '' {
			adapter.options.strings['url']
		} else {
			'ws://127.0.0.1:4500'
		}
		model:              if adapter.options.strings['model'].trim_space() != '' {
			adapter.options.strings['model']
		} else {
			'o4-mini'
		}
		effort:             if adapter.options.strings['effort'].trim_space() != '' {
			adapter.options.strings['effort']
		} else {
			'medium'
		}
		cwd:                adapter.options.strings['cwd']
		approval_policy:    if adapter.options.strings['approval_policy'].trim_space() != '' {
			adapter.options.strings['approval_policy']
		} else {
			'never'
		}
		sandbox:            if adapter.options.strings['sandbox'].trim_space() != '' {
			adapter.options.strings['sandbox']
		} else {
			'workspaceWrite'
		}
		reconnect_delay_ms: if adapter.options.ints['reconnect_delay_ms'] > 0 {
			adapter.options.ints['reconnect_delay_ms']
		} else {
			3000
		}
		flush_interval_ms:  if adapter.options.ints['flush_interval_ms'] > 0 {
			adapter.options.ints['flush_interval_ms']
		} else {
			400
		}
	}, adapter.options.bools['ollama_enabled'] || fallback.ollama_enabled
}

fn provider_adapter_for_listener(plan runtime_plan.RuntimePlan, listener_id string, kind string) ?runtime_plan.AdapterPlan {
	if adapter := plan.listener_adapter(listener_id, kind) {
		return adapter
	}
	if plan.source.compatibility {
		return plan.first_adapter_by_kind(kind)
	}
	return none
}

fn bridge_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string) ?provider.BridgeRuntimeSettings {
	relay := bridge_relay_for_listener(plan, listener_id)?
	return provider.BridgeRuntimeSettings{
		enabled:   config.CliArgs.parse_boolish(relay.options.strings['enabled'])
		ws_url:    relay.options.strings['url']
		client_id: relay.options.strings['node_id']
		token:     relay.options.strings['token']
		target_id: relay.options.strings['target_id']
	}
}

fn bridge_relay_for_listener(plan runtime_plan.RuntimePlan, listener_id string) ?runtime_plan.RelayPlan {
	for relay_id in plan.listener_relay_delivery_target_ids(listener_id) {
		relay := plan.relays[relay_id] or { continue }
		if relay.carrier == 'websocket' {
			return relay
		}
	}
	for relay_id in plan.relay_ids_for_listener(listener_id) {
		relay := plan.relays[relay_id] or { continue }
		if relay.carrier == 'websocket' {
			return relay
		}
	}
	if plan.source.compatibility {
		return plan.first_relay_by_carrier('websocket')
	}
	return none
}
