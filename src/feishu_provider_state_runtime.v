module main

import feishu
import x.json2

fn (hub ProviderRuntimeHub) feishu_runtime_enabled() bool {
	return hub.feishu.enabled || hub.provider_instance_list('feishu').len > 0
}

fn (app &App) feishu_runtime_enabled() bool {
	return app.providers.feishu_runtime_enabled()
}

fn (hub ProviderRuntimeHub) feishu_runtime_has_dynamic_app(name string) bool {
	return hub.provider_instance_get('feishu', name) != none
}

fn (app &App) feishu_runtime_has_dynamic_app(name string) bool {
	return app.providers.feishu_runtime_has_dynamic_app(name)
}

fn (hub ProviderRuntimeHub) feishu_runtime_has_static_app(name string) bool {
	if name in hub.feishu.static_apps {
		return true
	}
	if hub.feishu.static_apps.len == 0 && name in hub.feishu.apps
		&& !hub.feishu_runtime_has_dynamic_app(name) {
		return true
	}
	return false
}

fn (app &App) feishu_runtime_has_static_app(name string) bool {
	return app.providers.feishu_runtime_has_static_app(name)
}

fn (hub ProviderRuntimeHub) feishu_runtime_app_source(name string) string {
	has_static := hub.feishu_runtime_has_static_app(name)
	has_dynamic := hub.feishu_runtime_has_dynamic_app(name)
	if has_static && has_dynamic {
		return 'mixed'
	}
	if has_dynamic {
		return 'dynamic'
	}
	if has_static {
		return 'static'
	}
	if name in hub.feishu.apps {
		return 'runtime'
	}
	return 'unknown'
}

fn (app &App) feishu_runtime_app_source(name string) string {
	return app.providers.feishu_runtime_app_source(name)
}

fn (hub ProviderRuntimeHub) feishu_runtime_ready() bool {
	return hub.feishu_runtime_enabled() && hub.feishu.app_names().len > 0
}

fn (app &App) feishu_runtime_ready() bool {
	return app.providers.feishu_runtime_ready()
}

fn (hub ProviderRuntimeHub) feishu_runtime_bridge_proxy_only() bool {
	return hub.feishu_card_bridge_enabled() && hub.feishu.app_names().len == 0
}

fn (app &App) feishu_runtime_bridge_proxy_only() bool {
	return app.providers.feishu_runtime_bridge_proxy_only()
}

fn (hub ProviderRuntimeHub) feishu_runtime_callback_token_valid(app_name string, payload string) bool {
	cfg := hub.feishu.app_config(app_name) or { return false }
	if cfg.verification_token.trim_space() == '' {
		return true
	}
	parsed := json2.decode[json2.Any](payload) or { return false }
	root := parsed.as_map()
	token := feishu.JsonField.string(root, 'token')
	return token != '' && token == cfg.verification_token
}

fn (app &App) feishu_runtime_callback_token_valid(app_name string, payload string) bool {
	return app.providers.feishu_runtime_callback_token_valid(app_name, payload)
}

fn (mut hub ProviderRuntimeHub) feishu_runtime_snapshot() feishu.RuntimeSnapshot {
	hub.feishu.mu.@lock()
	defer {
		hub.feishu.mu.unlock()
	}
	mut apps := []feishu.RuntimeAppSnapshot{}
	mut connected_count := 0
	for name in hub.feishu.app_names() {
		runtime := hub.feishu.runtime[name] or { feishu.ProviderRuntime.new(name) }
		if runtime.is_connected() {
			connected_count++
		}
		apps << runtime.app_snapshot_with_source(name, hub.feishu_runtime_enabled(),
			hub.feishu.open_base_url, hub.feishu_runtime_app_source(name),
			hub.feishu_runtime_has_static_app(name), hub.feishu_runtime_has_dynamic_app(name))
	}
	return feishu.RuntimeSnapshot{
		enabled:         hub.feishu_runtime_enabled()
		configured:      hub.feishu_runtime_ready()
		app_count:       apps.len
		connected_count: connected_count
		default_app:     hub.feishu.default_app_name()
		apps:            apps
	}
}

fn (mut app App) feishu_runtime_snapshot() feishu.RuntimeSnapshot {
	return app.providers.feishu_runtime_snapshot()
}

fn (mut hub ProviderRuntimeHub) feishu_runtime_app_snapshot(name string) ?feishu.RuntimeAppSnapshot {
	snapshot := hub.feishu_runtime_snapshot()
	for item in snapshot.apps {
		if item.name == name {
			return item
		}
	}
	return none
}

fn (mut app App) feishu_runtime_app_snapshot(name string) ?feishu.RuntimeAppSnapshot {
	return app.providers.feishu_runtime_app_snapshot(name)
}

fn (mut app App) provider_runtime_feishu_snapshot() feishu.RuntimeSnapshot {
	return app.providers.feishu_runtime_snapshot()
}

fn (mut app App) provider_runtime_feishu_app_snapshot(name string) ?feishu.RuntimeAppSnapshot {
	return app.providers.feishu_runtime_app_snapshot(name)
}
