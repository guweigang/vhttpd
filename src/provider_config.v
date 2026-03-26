module main

// Provider runtime settings are resolved here so server.v can stay focused on
// transport/process orchestration instead of provider-specific defaults.

struct FeishuRuntimeSettings {
	enabled                    bool
	open_base_url              string
	reconnect_delay_ms         int
	token_refresh_skew_seconds int
	recent_event_limit         int
	apps                       map[string]FeishuAppConfig
}

struct CodexRuntimeSettings {
	enabled            bool
	url                string
	model              string
	effort             string
	cwd                string
	approval_policy    string
	sandbox            string
	reconnect_delay_ms int
	flush_interval_ms  int
}

struct ProviderRuntimeSettings {
	feishu FeishuRuntimeSettings
	codex  CodexRuntimeSettings
	ollama_enabled bool
}

fn resolve_provider_runtime_settings(args []string, cfg VhttpdConfig) ProviderRuntimeSettings {
	feishu_enabled := arg_bool_or(args, '--feishu-enabled', cfg.feishu.enabled)
	feishu_app_id := arg_string_or(args, '--feishu-app-id', '')
	feishu_app_secret := arg_string_or(args, '--feishu-app-secret', '')
	feishu_open_base_url := normalize_feishu_open_base(arg_string_or(args, '--feishu-open-base-url',
		cfg.feishu.open_base_url))
	mut feishu_apps := cfg.feishu.apps.clone()
	if feishu_app_id.trim_space() != '' || feishu_app_secret.trim_space() != '' {
		feishu_apps['main'] = FeishuAppConfig{
			app_id:     feishu_app_id
			app_secret: feishu_app_secret
		}
	}

	return ProviderRuntimeSettings{
		feishu: FeishuRuntimeSettings{
			enabled:                    feishu_enabled
			open_base_url:              feishu_open_base_url
			reconnect_delay_ms:         if cfg.feishu.reconnect_delay_ms > 0 { cfg.feishu.reconnect_delay_ms } else { 3000 }
			token_refresh_skew_seconds: if cfg.feishu.token_refresh_skew_seconds > 0 {
				cfg.feishu.token_refresh_skew_seconds
			} else {
				60
			}
			recent_event_limit:         if cfg.feishu.recent_event_limit > 0 { cfg.feishu.recent_event_limit } else { 20 }
			apps:                       feishu_apps.clone()
		}
		codex: CodexRuntimeSettings{
			enabled:            cfg.codex.enabled
			url:                if cfg.codex.url.trim_space() != '' { cfg.codex.url } else { 'ws://127.0.0.1:4500' }
			model:              if cfg.codex.model.trim_space() != '' { cfg.codex.model } else { 'o4-mini' }
			effort:             if cfg.codex.effort.trim_space() != '' { cfg.codex.effort } else { 'medium' }
			cwd:                cfg.codex.cwd
			approval_policy:    if cfg.codex.approval_policy.trim_space() != '' {
				cfg.codex.approval_policy
			} else {
				'never'
			}
			sandbox:            if cfg.codex.sandbox.trim_space() != '' { cfg.codex.sandbox } else { 'workspaceWrite' }
			reconnect_delay_ms: if cfg.codex.reconnect_delay_ms > 0 { cfg.codex.reconnect_delay_ms } else { 3000 }
			flush_interval_ms:  if cfg.codex.flush_interval_ms > 0 { cfg.codex.flush_interval_ms } else { 400 }
		}
		ollama_enabled: arg_bool_or(args, '--ollama-enabled', false)
	}
}
