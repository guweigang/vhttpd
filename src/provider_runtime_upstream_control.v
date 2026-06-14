module main

import provider

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
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	return match name {
		feishu_name {
			if app.providers.feishu.reconnect_delay_ms > 0 {
				app.providers.feishu.reconnect_delay_ms
			} else {
				3000
			}
		}
		codex_name {
			app.codex_provider_reconnect_delay_ms(instance)
		}
		else {
			3000
		}
	}
}

pub fn (mut app App) provider_runtime_on_connecting(name string, instance string) {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	match name {
		feishu_name {
			app.providers.feishu.note_connecting(instance)
		}
		codex_name {
			app.codex_provider_on_connecting(instance)
		}
		else {}
	}
}

pub fn (mut app App) provider_runtime_on_connected(name string, instance string, ws_url string) {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	match name {
		feishu_name {
			app.providers.feishu.note_connected(instance, ws_url)
		}
		codex_name {
			app.codex_provider_on_connected(instance, ws_url)
		}
		else {}
	}
}

pub fn (mut app App) provider_runtime_on_disconnected(name string, instance string, reason string) {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	match name {
		feishu_name {
			app.providers.feishu.note_disconnected(instance, reason)
		}
		codex_name {
			app.codex_provider_on_disconnected(instance, reason)
		}
		else {}
	}
}
