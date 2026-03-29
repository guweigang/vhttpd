module main

import json
import time
import x.json2

pub struct ProviderInstanceSpec {
pub mut:
	provider      string
	instance      string
	config_json   string
	desired_state string
	created_at    i64
	updated_at    i64
}

pub struct AdminProviderInstanceSnapshot {
pub:
	provider           string
	instance           string
	source             string
	stored             bool
	runtime_configured bool     @[json: 'runtime_configured']
	runtime_connected  bool     @[json: 'runtime_connected']
	runtime_url        string   @[json: 'runtime_url']
	config_present     bool     @[json: 'config_present']
	config_fields      []string @[json: 'config_fields']
	desired_state      string   @[json: 'desired_state']
	created_at         i64      @[json: 'created_at']
	updated_at         i64      @[json: 'updated_at']
}

fn provider_instance_normalize_name(instance string) string {
	name := instance.trim_space()
	if name == '' || name == 'default' {
		return 'main'
	}
	return name
}

fn provider_instance_key(provider string, instance string) string {
	return '${provider.trim_space()}/${provider_instance_normalize_name(instance)}'
}

fn provider_instance_config_fields(config_json string) []string {
	raw := config_json.trim_space()
	if raw == '' {
		return []string{}
	}
	parsed := json2.decode[json2.Any](raw) or { return []string{} }
	root := parsed.as_map()
	mut fields := []string{}
	for key, _ in root {
		fields << key
	}
	fields.sort()
	return fields
}

fn provider_instance_runtime_snapshot(mut app App, provider string, instance string) (WebSocketUpstreamSnapshot, bool) {
	if snapshot := app.provider_runtime_upstream_snapshot(provider, instance) {
		return snapshot, true
	}
	return WebSocketUpstreamSnapshot{}, false
}

pub fn (mut app App) provider_instance_upsert(spec ProviderInstanceSpec) ProviderInstanceSpec {
	key := provider_instance_key(spec.provider, spec.instance)
	now_ms := time.now().unix_milli()
	existing := app.provider_instance_specs[key] or { ProviderInstanceSpec{} }
	next := ProviderInstanceSpec{
		provider:      spec.provider.trim_space()
		instance:      provider_instance_normalize_name(spec.instance)
		config_json:   spec.config_json
		desired_state: if spec.desired_state.trim_space() == '' {
			'connected'
		} else {
			spec.desired_state.trim_space()
		}
		created_at:    if existing.created_at > 0 { existing.created_at } else { now_ms }
		updated_at:    now_ms
	}
	app.provider_instance_specs[key] = next
	return next
}

pub fn (app &App) provider_instance_get(provider string, instance string) ?ProviderInstanceSpec {
	key := provider_instance_key(provider, instance)
	if key !in app.provider_instance_specs {
		return none
	}
	return app.provider_instance_specs[key]
}

pub fn (app &App) provider_instance_list(provider string) []ProviderInstanceSpec {
	mut out := []ProviderInstanceSpec{}
	for _, spec in app.provider_instance_specs {
		if provider.trim_space() != '' && spec.provider != provider.trim_space() {
			continue
		}
		out << spec
	}
	out.sort_with_compare(fn (a &ProviderInstanceSpec, b &ProviderInstanceSpec) int {
		left := '${a.provider}/${a.instance}'
		right := '${b.provider}/${b.instance}'
		if left < right {
			return -1
		}
		if left > right {
			return 1
		}
		return 0
	})
	return out
}

pub fn (mut app App) admin_provider_instance_snapshots(provider_filter string) []AdminProviderInstanceSnapshot {
	filter := provider_filter.trim_space()
	mut out := []AdminProviderInstanceSnapshot{}
	for _, spec in app.provider_instance_specs {
		if filter != '' && spec.provider != filter {
			continue
		}
		upstream, upstream_ok := provider_instance_runtime_snapshot(mut app, spec.provider,
			spec.instance)
		out << AdminProviderInstanceSnapshot{
			provider:           spec.provider
			instance:           spec.instance
			source:             match spec.provider {
				'feishu' { app.feishu_runtime_app_source(spec.instance) }
				'codex' { 'dynamic' }
				else { 'dynamic' }
			}
			stored:             true
			runtime_configured: upstream_ok && upstream.configured
			runtime_connected:  upstream_ok && upstream.connected
			runtime_url:        if upstream_ok { upstream.url } else { '' }
			config_present:     spec.config_json.trim_space() != ''
			config_fields:      provider_instance_config_fields(spec.config_json)
			desired_state:      spec.desired_state
			created_at:         spec.created_at
			updated_at:         spec.updated_at
		}
	}
	if filter == '' || filter == 'feishu' {
		for name, cfg in app.feishu_static_apps {
			if app.provider_instance_get('feishu', name) != none {
				continue
			}
			upstream, upstream_ok := provider_instance_runtime_snapshot(mut app, 'feishu',
				name)
			out << AdminProviderInstanceSnapshot{
				provider:           'feishu'
				instance:           name
				source:             'static'
				stored:             false
				runtime_configured: upstream_ok && upstream.configured
				runtime_connected:  upstream_ok && upstream.connected
				runtime_url:        if upstream_ok { upstream.url } else { '' }
				config_present:     true
				config_fields:      provider_instance_config_fields(json.encode(cfg))
				desired_state:      'connected'
				created_at:         0
				updated_at:         0
			}
		}
	}
	out.sort_with_compare(fn (a &AdminProviderInstanceSnapshot, b &AdminProviderInstanceSnapshot) int {
		left := '${a.provider}/${a.instance}'
		right := '${b.provider}/${b.instance}'
		if left < right {
			return -1
		}
		if left > right {
			return 1
		}
		return 0
	})
	return out
}

pub fn (mut app App) provider_instance_apply(spec ProviderInstanceSpec) ! {
	match spec.provider {
		'feishu' {
			if spec.config_json.trim_space() == '' {
				return
			}
			cfg := json.decode(FeishuAppConfig, spec.config_json) or {
				return error('provider_instance_invalid_feishu_config:${err}')
			}
			app.feishu_apps[spec.instance] = cfg
			app.feishu_runtime_ensure(spec.instance)
			_ = app.ensure_websocket_upstream_provider_running('feishu', spec.instance)
		}
		'codex' {
			if spec.config_json.trim_space() == '' {
				return
			}
			cfg := json.decode(CodexConfig, spec.config_json) or {
				return error('provider_instance_invalid_codex_config:${err}')
			}
			mut rt := app.codex_runtime_ensure_instance(spec.instance)
			if cfg.url.trim_space() != '' {
				rt.url = cfg.url
			}
			if cfg.model.trim_space() != '' {
				rt.model = cfg.model
			}
			if cfg.effort.trim_space() != '' {
				rt.effort = cfg.effort
			}
			if cfg.cwd.trim_space() != '' {
				rt.cwd = cfg.cwd
			}
			if cfg.approval_policy.trim_space() != '' {
				rt.approval_policy = cfg.approval_policy
			}
			if cfg.sandbox.trim_space() != '' {
				rt.sandbox = cfg.sandbox
			}
			if cfg.reconnect_delay_ms > 0 {
				rt.reconnect_delay_ms = cfg.reconnect_delay_ms
			}
			if cfg.flush_interval_ms > 0 {
				rt.flush_interval_ms = cfg.flush_interval_ms
			}
			app.codex_runtime_update(spec.instance, rt)
			_ = app.ensure_websocket_upstream_provider_running('codex', spec.instance)
		}
		else {}
	}
}

pub fn (mut app App) provider_instance_ensure(provider string, instance string) !ProviderInstanceSpec {
	normalized_instance := provider_instance_normalize_name(instance)
	if spec := app.provider_instance_get(provider, normalized_instance) {
		if provider in ['codex', 'feishu'] {
			app.provider_instance_apply(spec) or {}
		}
		return spec
	}
	if provider == 'feishu' {
		if cfg := app.feishu_apps[normalized_instance] {
			spec := app.provider_instance_upsert(ProviderInstanceSpec{
				provider:      'feishu'
				instance:      normalized_instance
				config_json:   json.encode(cfg)
				desired_state: 'connected'
			})
			app.provider_instance_apply(spec) or {}
			return spec
		}
	}
	if provider == 'codex' && normalized_instance == 'main' && app.provider_enabled('codex') {
		return app.provider_instance_upsert(ProviderInstanceSpec{
			provider:      'codex'
			instance:      'main'
			config_json:   ''
			desired_state: 'connected'
		})
	}
	return error('provider_instance_not_found:${provider}/${normalized_instance}')
}
