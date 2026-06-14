module main

import dbx
import provider

pub fn (app &App) provider_bootstrap_enabled(name string) bool {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	ollama_name := provider.ProviderName.ollama()
	db_name := provider.ProviderName.db()
	return match name {
		feishu_name {
			app.feishu_runtime_enabled()
		}
		codex_name {
			app.providers.codex.runtime.enabled || app.provider_instance_list(codex_name).len > 0
		}
		ollama_name {
			app.providers.codex.ollama_enabled
		}
		db_name {
			app.transport.db.enabled && dbx.Runtime.compiled()
		}
		else {
			false
		}
	}
}

pub fn (mut app App) provider_runtime_ready(name string) bool {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	ollama_name := provider.ProviderName.ollama()
	db_name := provider.ProviderName.db()
	return match name {
		feishu_name { app.feishu_runtime_ready() }
		codex_name { app.provider_enabled(codex_name) }
		ollama_name { app.provider_enabled(ollama_name) }
		db_name { app.provider_enabled(db_name) }
		else { false }
	}
}

pub fn (mut app App) provider_runtime_default_instance(name string) string {
	if name == provider.ProviderName.feishu() {
		return app.providers.feishu.default_app_name()
	}
	return provider.ProviderName.default_instance(name)
}

pub fn (mut app App) provider_runtime_instances(name string) []string {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	ollama_name := provider.ProviderName.ollama()
	db_name := provider.ProviderName.db()
	return match name {
		feishu_name {
			app.providers.feishu.app_names()
		}
		codex_name {
			mut out := []string{}
			if app.provider_enabled(codex_name) {
				out << 'main'
			}
			for spec in app.provider_instance_list(codex_name) {
				if spec.instance !in out {
					out << spec.instance
				}
			}
			out.sort()
			out
		}
		ollama_name {
			if app.provider_runtime_ready(ollama_name) {
				['main']
			} else {
				[]string{}
			}
		}
		db_name {
			if app.provider_runtime_ready(db_name) {
				['main']
			} else {
				[]string{}
			}
		}
		else {
			[]string{}
		}
	}
}
