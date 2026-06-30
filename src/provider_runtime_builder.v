module main

import codex
import feishu
import provider

fn ProviderRuntimeHub.new(settings provider.ProviderRuntimeSettings) ProviderRuntimeHub {
	return ProviderRuntimeHub{
		registry:  ProviderHost{
			registry: map[string]Provider{}
			specs:    map[string]ProviderSpec{}
		}
		instances: provider.ProviderInstanceRegistry{
			specs: map[string]provider.ProviderInstanceSpec{}
		}
		codex:     codex_state_from_settings(settings)
		feishu:    feishu_state_from_settings(settings)
	}
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
