module main

import feishu
import x.json2

fn (app &App) feishu_runtime_enabled() bool {
	return app.providers.feishu.enabled || app.provider_instance_list('feishu').len > 0
}

fn (app &App) feishu_runtime_has_dynamic_app(name string) bool {
	return app.provider_instance_get('feishu', name) != none
}

fn (app &App) feishu_runtime_has_static_app(name string) bool {
	if name in app.providers.feishu.static_apps {
		return true
	}
	if app.providers.feishu.static_apps.len == 0 && name in app.providers.feishu.apps
		&& !app.feishu_runtime_has_dynamic_app(name) {
		return true
	}
	return false
}

fn (app &App) feishu_runtime_app_source(name string) string {
	has_static := app.feishu_runtime_has_static_app(name)
	has_dynamic := app.feishu_runtime_has_dynamic_app(name)
	if has_static && has_dynamic {
		return 'mixed'
	}
	if has_dynamic {
		return 'dynamic'
	}
	if has_static {
		return 'static'
	}
	if name in app.providers.feishu.apps {
		return 'runtime'
	}
	return 'unknown'
}

fn (app &App) feishu_runtime_ready() bool {
	return app.feishu_runtime_enabled() && app.providers.feishu.app_names().len > 0
}

fn (app &App) feishu_runtime_bridge_proxy_only() bool {
	return app.feishu_card_bridge_enabled() && app.providers.feishu.app_names().len == 0
}

fn (app &App) feishu_runtime_callback_token_valid(app_name string, payload string) bool {
	cfg := app.providers.feishu.app_config(app_name) or { return false }
	if cfg.verification_token.trim_space() == '' {
		return true
	}
	parsed := json2.decode[json2.Any](payload) or { return false }
	root := parsed.as_map()
	token := feishu.JsonField.string(root, 'token')
	return token != '' && token == cfg.verification_token
}

fn (mut app App) feishu_runtime_snapshot() feishu.RuntimeSnapshot {
	app.providers.feishu.mu.@lock()
	defer {
		app.providers.feishu.mu.unlock()
	}
	mut apps := []feishu.RuntimeAppSnapshot{}
	mut connected_count := 0
	for name in app.providers.feishu.app_names() {
		runtime := app.providers.feishu.runtime[name] or { feishu.ProviderRuntime.new(name) }
		if runtime.is_connected() {
			connected_count++
		}
		apps << runtime.app_snapshot_with_source(name, app.feishu_runtime_enabled(),
			app.providers.feishu.open_base_url, app.feishu_runtime_app_source(name),
			app.feishu_runtime_has_static_app(name), app.feishu_runtime_has_dynamic_app(name))
	}
	return feishu.RuntimeSnapshot{
		enabled:         app.feishu_runtime_enabled()
		configured:      app.feishu_runtime_ready()
		app_count:       apps.len
		connected_count: connected_count
		default_app:     app.providers.feishu.default_app_name()
		apps:            apps
	}
}

fn (mut app App) feishu_runtime_app_snapshot(name string) ?feishu.RuntimeAppSnapshot {
	snapshot := app.feishu_runtime_snapshot()
	for item in snapshot.apps {
		if item.name == name {
			return item
		}
	}
	return none
}

fn (mut app App) provider_runtime_feishu_snapshot() feishu.RuntimeSnapshot {
	return app.feishu_runtime_snapshot()
}

fn (mut app App) provider_runtime_feishu_app_snapshot(name string) ?feishu.RuntimeAppSnapshot {
	return app.feishu_runtime_app_snapshot(name)
}
