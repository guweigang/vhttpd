module main

import codex
import feishu
import provider

fn ProviderRuntimeHub.new(settings provider.ProviderRuntimeSettings) ProviderRuntimeHub {
	return ProviderRuntimeHub{
		registry:             ProviderHost{
			registry: map[string]Provider{}
			specs:    map[string]ProviderSpec{}
		}
		runtime_drivers:      settings.runtime_drivers.clone()
		runtime_plugins:      settings.runtime_plugins.clone()
		runtime_capabilities: settings.runtime_capabilities.clone()
		runtime_options:      settings.runtime_options.clone()
		instances:            provider.ProviderInstanceRegistry{
			specs: map[string]provider.ProviderInstanceSpec{}
		}
		codex:                codex_state_from_settings(settings)
		feishu:               feishu_state_from_settings(settings)
	}
}

fn (hub ProviderRuntimeHub) provider_runtime_driver(name string) string {
	driver := hub.runtime_drivers[name] or { '' }
	if driver.trim_space() == '' {
		return 'native'
	}
	return driver
}

fn (hub ProviderRuntimeHub) provider_runtime_plugin(name string) string {
	return hub.runtime_plugins[name] or { '' }
}

fn (hub ProviderRuntimeHub) provider_runtime_capability(provider_name string, action string) string {
	if capabilities := hub.runtime_capabilities[provider_name] {
		capability := capabilities[action] or { '' }
		if capability.trim_space() != '' {
			return capability
		}
	}
	return 'provider.${provider_name}.${action}'
}

fn (hub ProviderRuntimeHub) provider_runtime_option(provider_name string, key string) string {
	if options := hub.runtime_options[provider_name] {
		return options[key] or { '' }
	}
	return ''
}

fn (mut hub ProviderRuntimeHub) apply_provider_runtime_settings(settings provider.ProviderRuntimeSettings) {
	hub.runtime_drivers = settings.runtime_drivers.clone()
	hub.runtime_plugins = settings.runtime_plugins.clone()
	hub.runtime_capabilities = settings.runtime_capabilities.clone()
	hub.runtime_options = settings.runtime_options.clone()
	for name, spec in hub.registry.specs {
		hub.registry.specs[name] = ProviderSpec{
			...spec
			runtime_driver: hub.provider_runtime_driver(name)
		}
	}
}

fn (hub ProviderRuntimeHub) provider_runtime_settings_snapshot() provider.ProviderRuntimeSettings {
	return provider.ProviderRuntimeSettings{
		runtime_drivers:      hub.runtime_drivers.clone()
		runtime_plugins:      hub.runtime_plugins.clone()
		runtime_capabilities: hub.runtime_capabilities.clone()
		runtime_options:      hub.runtime_options.clone()
		feishu:               provider.FeishuRuntimeSettings{
			runtime_driver: hub.provider_runtime_driver('feishu')
			runtime_plugin: hub.provider_runtime_plugin('feishu')
		}
	}
}

fn (mut app App) provider_runtime_settings_snapshot() provider.ProviderRuntimeSettings {
	return app.providers.provider_runtime_settings_snapshot()
}

fn codex_state_from_settings(settings provider.ProviderRuntimeSettings) codex.CodexState {
	return codex.CodexState.new(codex.RuntimeSettings{
		enabled:            settings.codex.enabled
		url:                settings.codex.url
		model:              settings.codex.model
		effort:             settings.codex.effort
		cwd:                settings.codex.cwd
		approval_policy:    settings.codex.approval_policy
		sandbox:            settings.codex.sandbox
		reconnect_delay_ms: settings.codex.reconnect_delay_ms
		flush_interval_ms:  settings.codex.flush_interval_ms
		ollama_enabled:     settings.ollama_enabled
	})
}

fn feishu_state_from_settings(settings provider.ProviderRuntimeSettings) feishu.FeishuState {
	return feishu.FeishuState.new(feishu.StateSettings{
		enabled:                    settings.feishu.enabled
		open_base_url:              settings.feishu.open_base_url
		reconnect_delay_ms:         settings.feishu.reconnect_delay_ms
		token_refresh_skew_seconds: settings.feishu.token_refresh_skew_seconds
		recent_event_limit:         settings.feishu.recent_event_limit
		apps:                       settings.feishu.apps.clone()
		bridge:                     feishu.BridgeSettings{
			enabled:   settings.bridge.enabled
			ws_url:    settings.bridge.ws_url
			client_id: settings.bridge.client_id
			token:     settings.bridge.token
			target_id: settings.bridge.target_id
		}
	})
}
