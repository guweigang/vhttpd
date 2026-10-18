module main

import provider
import upstream

@[heap]
struct InjectedInstanceCalls {
mut:
	applied       []string
	codex_enabled bool
}

fn test_provider_instance_context_is_injected_without_app() {
	mut calls := &InjectedInstanceCalls{}
	ctx := ProviderInstanceRuntimeContext{
		runtime_snapshot_fn: fn (name string, instance string) (upstream.UpstreamSnapshot, bool) {
			return upstream.UpstreamSnapshot{ provider: name, instance: instance }, true
		}
		source_fn:           fn (_name string, _instance string) string { return 'static' }
		static_specs_fn:     fn () []ProviderInstanceStaticSpec {
			return []ProviderInstanceStaticSpec{}
		}
		static_spec_fn:      fn (name string, instance string) ?provider.ProviderInstanceSpec {
			if name != 'feishu' { return none }
			return provider.ProviderInstanceSpec{ provider: name, instance: instance, config_json: '{}' }
		}
		apply_fn:            fn [mut calls] (spec provider.ProviderInstanceSpec) ! {
			calls.applied << spec.key()
			return error('injected_apply_failure')
		}
		provider_enabled_fn: fn [mut calls] (name string) bool {
			return name == 'codex' && calls.codex_enabled
		}
	}
	mut registry := provider.ProviderInstanceRegistry{}
	// Ensure intentionally tolerates apply failures when an instance is found.
	spec := ProviderInstanceRuntime.ensure(mut registry, ctx, 'feishu', 'default') or { panic(err) }
	assert spec.instance == 'main'
	assert calls.applied == ['feishu/main']
	ProviderInstanceRuntime.ensure(mut registry, ctx, 'feishu', '') or { panic(err) }
	assert calls.applied.len == 2
	mut failed := false
	ProviderInstanceRuntime.apply(ctx, spec) or {
		assert err.msg() == 'injected_apply_failure'
		failed = true
	}
	assert failed
	calls.codex_enabled = true
	default_spec := ProviderInstanceRuntime.ensure(mut registry, ctx, 'codex', 'default') or { panic(err) }
	assert default_spec.instance == 'main'
	assert default_spec.desired_state == 'connected'
	assert ctx.source('feishu', 'main') == 'static'
	assert ctx.static_specs().len == 0
	snapshot, found := ctx.runtime_snapshot('feishu', 'main')
	assert found && snapshot.instance == 'main'
}
