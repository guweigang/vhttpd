module main

import provider

fn (mut hub ProviderRuntimeHub) provider_runtime_reconnect_delay_ms(name string, instance string) int {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	return match name {
		feishu_name {
			if hub.feishu.reconnect_delay_ms > 0 {
				hub.feishu.reconnect_delay_ms
			} else {
				3000
			}
		}
		codex_name {
			hub.codex_provider_reconnect_delay_ms(instance)
		}
		else {
			3000
		}
	}
}

fn (mut hub ProviderRuntimeHub) provider_runtime_on_connecting(name string, instance string) {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	match name {
		feishu_name {
			hub.feishu.note_connecting(instance)
		}
		codex_name {
			hub.codex_provider_on_connecting(instance)
		}
		else {}
	}
}

fn (mut hub ProviderRuntimeHub) provider_runtime_on_connected(name string, instance string, ws_url string) {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	match name {
		feishu_name {
			hub.feishu.note_connected(instance, ws_url)
		}
		codex_name {
			hub.codex_provider_on_connected(instance, ws_url)
		}
		else {}
	}
}

fn (mut hub ProviderRuntimeHub) provider_runtime_on_disconnected(name string, instance string, reason string) {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	match name {
		feishu_name {
			hub.feishu.note_disconnected(instance, reason)
		}
		codex_name {
			hub.codex_provider_on_disconnected(instance, reason)
		}
		else {}
	}
}

pub fn (mut app App) provider_runtime_pull_url(name string, instance string) !string {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	return match name {
		feishu_name { app.feishu_provider_pull_ws_endpoint(instance) }
		codex_name { app.codex_provider_pull_url(instance) }
		else { error('unknown provider ${name}') }
	}
}

pub fn (mut app App) provider_runtime_reconnect_delay_ms(name string, instance string) int {
	return app.providers.provider_runtime_reconnect_delay_ms(name, instance)
}

pub fn (mut app App) provider_runtime_on_connecting(name string, instance string) {
	app.providers.provider_runtime_on_connecting(name, instance)
}

pub fn (mut app App) provider_runtime_on_connected(name string, instance string, ws_url string) {
	app.providers.provider_runtime_on_connected(name, instance, ws_url)
}

pub fn (mut app App) provider_runtime_on_disconnected(name string, instance string, reason string) {
	app.providers.provider_runtime_on_disconnected(name, instance, reason)
}
