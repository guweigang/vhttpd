module main

import provider
import config
import codex
import json2 as json

struct PreparedProviderInstance {
	spec          provider.ProviderInstanceSpec
	changed       bool
	fields        map[string]bool
	feishu_config config.FeishuAppConfig
	codex_config  config.CodexConfig
}

struct ProviderInstanceCommit {
	spec     provider.ProviderInstanceSpec
	snapshot provider.AdminProviderInstanceSnapshot
}

// Decode before admission so invalid commands cannot leave a desired-state row.
fn prepare_provider_instance(spec provider.ProviderInstanceSpec) !PreparedProviderInstance {
	mut normalized := spec
	normalized.provider = spec.normalized_provider()
	normalized.instance = spec.normalized_instance()
	normalized.desired_state = spec.desired_state_or_default()
	if normalized.config_json.trim_space() == '' {
		return PreparedProviderInstance{ spec: normalized }
	}
	return match normalized.provider {
		'feishu' {
			cfg := json.decode[config.FeishuAppConfig](normalized.config_json) or { return error('provider_instance_invalid_feishu_config:${err}') }
			PreparedProviderInstance{ spec: normalized, changed: true, feishu_config: cfg }
		}
		'codex' {
			cfg := json.decode[config.CodexConfig](normalized.config_json) or { return error('provider_instance_invalid_codex_config:${err}') }
			fields := json.decode[map[string]json.Any](normalized.config_json) or { return error('provider_instance_invalid_codex_config:${err}') }
			mut names := map[string]bool{}
			for name in fields.keys() { names[name] = true }
			PreparedProviderInstance{ spec: normalized, changed: true, codex_config: cfg, fields: names }
		}
		else { PreparedProviderInstance{ spec: normalized } }
	}
}

// App.mu owns the configuration/registry commit and snapshot read boundary.
// Domain locks protect runtime fields; no network or injected callback runs here.
fn (mut app App) apply_provider_instance_unlocked(prepared PreparedProviderInstance) {
	if !prepared.changed { return }
	spec := prepared.spec
	match spec.provider {
		'feishu' {
			app.providers.feishu.configure_app(spec.instance, prepared.feishu_config)
		}
		'codex' {
			cfg := prepared.codex_config
			app.providers.codex.mu.@lock()
			mut rt := codex_instance_for_control_unlocked(app.providers.codex, spec.instance)
			rt.configuration_generation++
			if prepared.fields['url'] && cfg.url.trim_space() != '' { rt.url = cfg.url }
			if prepared.fields['model'] && cfg.model.trim_space() != '' { rt.model = cfg.model }
			if prepared.fields['effort'] && cfg.effort.trim_space() != '' { rt.effort = cfg.effort }
			if prepared.fields['cwd'] && cfg.cwd.trim_space() != '' { rt.cwd = cfg.cwd }
			if prepared.fields['approval_policy'] && cfg.approval_policy.trim_space() != '' {
				rt.approval_policy = cfg.approval_policy
			}
			if prepared.fields['sandbox'] && cfg.sandbox.trim_space() != '' {
				rt.sandbox = cfg.sandbox
			}
			if prepared.fields['reconnect_delay_ms'] && cfg.reconnect_delay_ms > 0 {
				rt.reconnect_delay_ms = cfg.reconnect_delay_ms
			}
			if prepared.fields['flush_interval_ms'] && cfg.flush_interval_ms > 0 {
				rt.flush_interval_ms = cfg.flush_interval_ms
			}
			if spec.instance == 'main' {
				app.providers.codex.runtime = rt
			} else {
				app.providers.codex.instances[spec.instance] = rt
			}
			app.providers.codex.mu.unlock()
		}
		else {}
	}
}

fn codex_instance_for_control_unlocked(state &codex.CodexState, instance string) codex.ProviderRuntime {
	if instance == 'main' { return state.runtime }
	if rt := state.instances[instance] { return rt }
	return state.runtime.for_instance(instance)
}

fn (mut app App) start_provider_instance(prepared PreparedProviderInstance) {
	if prepared.changed {
		_ = app.ensure_websocket_upstream_provider_running(prepared.spec.provider, prepared.spec.instance)
	}
}

fn (mut app App) configure_provider_instance(spec provider.ProviderInstanceSpec) !ProviderInstanceCommit {
	prepared := prepare_provider_instance(spec)!
	if !app.lifecycle.shutdown.begin_start() { return error('provider_instance_app_stopping') }
	defer { app.lifecycle.shutdown.end_start() }
	app.mu.@lock()
	app.apply_provider_instance_unlocked(prepared)
	stored := app.providers.provider_instance_upsert(prepared.spec)
	snapshot := app.admin_provider_instance_snapshot_unlocked(stored.provider, stored.instance) or {
		app.mu.unlock()
		return error('provider_instance_snapshot_missing:${stored.provider}/${stored.instance}')
	}
	app.mu.unlock()
	// A later commit may already exist; this action resolves current config and
	// cannot replay the prepared config after unlocking.
	app.start_provider_instance(prepared)
	return ProviderInstanceCommit{ spec: stored, snapshot: snapshot }
}
