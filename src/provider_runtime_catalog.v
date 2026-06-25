module main

import dbx
import provider

fn (hub ProviderRuntimeHub) provider_bootstrap_enabled(name string, db_transport_enabled bool) bool {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	ollama_name := provider.ProviderName.ollama()
	db_name := provider.ProviderName.db()
	return match name {
		feishu_name {
			hub.feishu.enabled || hub.provider_instance_list(feishu_name).len > 0
		}
		codex_name {
			hub.codex.runtime.enabled || hub.provider_instance_list(codex_name).len > 0
		}
		ollama_name {
			hub.codex.ollama_enabled
		}
		db_name {
			db_transport_enabled && dbx.Runtime.compiled()
		}
		else {
			false
		}
	}
}

pub fn (app &App) provider_bootstrap_enabled(name string) bool {
	return app.providers.provider_bootstrap_enabled(name, app.transport.db.enabled)
}

fn (hub ProviderRuntimeHub) provider_runtime_ready(name string, db_transport_enabled bool) bool {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	ollama_name := provider.ProviderName.ollama()
	db_name := provider.ProviderName.db()
	return match name {
		feishu_name {
			hub.provider_bootstrap_enabled(feishu_name, db_transport_enabled)
				&& hub.feishu.app_names().len > 0
		}
		codex_name {
			hub.provider_enabled(codex_name, hub.provider_bootstrap_enabled(codex_name,
				db_transport_enabled))
		}
		ollama_name {
			hub.provider_enabled(ollama_name, hub.provider_bootstrap_enabled(ollama_name,
				db_transport_enabled))
		}
		db_name {
			hub.provider_enabled(db_name, hub.provider_bootstrap_enabled(db_name,
				db_transport_enabled))
		}
		else {
			false
		}
	}
}

pub fn (mut app App) provider_runtime_ready(name string) bool {
	return app.providers.provider_runtime_ready(name, app.transport.db.enabled)
}

fn (hub ProviderRuntimeHub) provider_runtime_default_instance(name string) string {
	if name == provider.ProviderName.feishu() {
		return hub.feishu.default_app_name()
	}
	return provider.ProviderName.default_instance(name)
}

pub fn (mut app App) provider_runtime_default_instance(name string) string {
	return app.providers.provider_runtime_default_instance(name)
}

fn (hub ProviderRuntimeHub) provider_runtime_instances(name string, db_transport_enabled bool) []string {
	feishu_name := provider.ProviderName.feishu()
	codex_name := provider.ProviderName.codex()
	ollama_name := provider.ProviderName.ollama()
	db_name := provider.ProviderName.db()
	return match name {
		feishu_name {
			hub.feishu.app_names()
		}
		codex_name {
			mut out := []string{}
			if hub.provider_enabled(codex_name, hub.provider_bootstrap_enabled(codex_name,
				db_transport_enabled))
			{
				out << 'main'
			}
			for spec in hub.provider_instance_list(codex_name) {
				if spec.instance !in out {
					out << spec.instance
				}
			}
			out.sort()
			out
		}
		ollama_name {
			if hub.provider_runtime_ready(ollama_name, db_transport_enabled) {
				['main']
			} else {
				[]string{}
			}
		}
		db_name {
			if hub.provider_runtime_ready(db_name, db_transport_enabled) {
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

pub fn (mut app App) provider_runtime_instances(name string) []string {
	return app.providers.provider_runtime_instances(name, app.transport.db.enabled)
}
