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
	return codex.CodexState{
		ollama_enabled: settings.ollama_enabled
		runtime:        codex.ProviderRuntime{
			enabled:             settings.codex.enabled
			url:                 settings.codex.url
			model:               settings.codex.model
			effort:              settings.codex.effort
			cwd:                 settings.codex.cwd
			approval_policy:     settings.codex.approval_policy
			sandbox:             settings.codex.sandbox
			reconnect_delay_ms:  settings.codex.reconnect_delay_ms
			flush_interval_ms:   settings.codex.flush_interval_ms
			pending_rpcs:        map[int]codex.PendingRpc{}
			stream_map:          map[string][]codex.CodexTarget{}
			err_bursts:          map[string][]string{}
			err_pending_flushes: map[string]bool{}
			thread_stream_map:   map[string]string{}
		}
		instances:      map[string]codex.ProviderRuntime{}
	}
}

fn feishu_state_from_settings(settings provider.ProviderRuntimeSettings) feishu.FeishuState {
	return feishu.FeishuState{
		enabled:                    settings.feishu.enabled
		open_base_url:              settings.feishu.open_base_url
		reconnect_delay_ms:         settings.feishu.reconnect_delay_ms
		token_refresh_skew_seconds: settings.feishu.token_refresh_skew_seconds
		recent_event_limit:         settings.feishu.recent_event_limit
		static_apps:                settings.feishu.apps.clone()
		apps:                       settings.feishu.apps.clone()
		runtime:                    map[string]feishu.ProviderRuntime{}
		buffers:                    map[string]feishu.StreamBuffer{}
		card_bridge_enabled_flag:   settings.bridge.enabled
		card_bridge_ws_url:         settings.bridge.ws_url
		card_bridge_client_id:      settings.bridge.client_id
		card_bridge_token:          settings.bridge.token
		card_bridge_target_id:      settings.bridge.target_id
	}
}
