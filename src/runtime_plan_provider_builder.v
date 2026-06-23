module main

import config
import feishu
import provider
import runtime_plan

fn provider_runtime_settings_from_plan(plan runtime_plan.RuntimePlan, fallback provider.ProviderRuntimeSettings) provider.ProviderRuntimeSettings {
	feishu_settings := feishu_runtime_settings_from_plan(plan) or { fallback.feishu }
	codex_settings, ollama_enabled := codex_runtime_settings_from_plan(plan, fallback)
	bridge_settings := bridge_runtime_settings_from_plan(plan) or { fallback.bridge }
	return provider.ProviderRuntimeSettings{
		feishu:         feishu_settings
		codex:          codex_settings
		bridge:         bridge_settings
		db:             fallback.db
		ollama_enabled: ollama_enabled
	}
}

fn feishu_runtime_settings_from_plan(plan runtime_plan.RuntimePlan) ?provider.FeishuRuntimeSettings {
	adapter := first_adapter_by_kind(plan, 'feishu-events')?
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

fn codex_runtime_settings_from_plan(plan runtime_plan.RuntimePlan, fallback provider.ProviderRuntimeSettings) (provider.CodexRuntimeSettings, bool) {
	adapter := first_adapter_by_kind(plan, 'codex') or {
		if openai_adapter := first_adapter_by_kind(plan, 'openai') {
			return fallback.codex, openai_adapter.options.bools['ollama_enabled'] || fallback.ollama_enabled
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

fn bridge_runtime_settings_from_plan(plan runtime_plan.RuntimePlan) ?provider.BridgeRuntimeSettings {
	relay := first_relay_by_carrier(plan, 'websocket')?
	return provider.BridgeRuntimeSettings{
		enabled:   config.CliArgs.parse_boolish(relay.options.strings['enabled'])
		ws_url:    relay.options.strings['url']
		client_id: relay.options.strings['node_id']
		token:     relay.options.strings['token']
		target_id: relay.options.strings['target_id']
	}
}

fn first_adapter_by_kind(plan runtime_plan.RuntimePlan, kind string) ?runtime_plan.AdapterPlan {
	mut ids := plan.adapters.keys()
	ids.sort()
	for id in ids {
		adapter := plan.adapters[id]
		if adapter.kind == kind {
			return adapter
		}
	}
	return none
}

fn first_relay_by_carrier(plan runtime_plan.RuntimePlan, carrier string) ?runtime_plan.RelayPlan {
	mut ids := plan.relays.keys()
	ids.sort()
	for id in ids {
		relay := plan.relays[id]
		if relay.carrier == carrier {
			return relay
		}
	}
	return none
}
