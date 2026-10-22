module main

import provider

@[heap]
struct LifecycleContextProbe {
mut:
	rows []string
}

fn lifecycle_probe_context(mut probe LifecycleContextProbe, label string) provider.RuntimeContext {
	return provider.RuntimeContext{
		start:    fn [mut probe, label] () ! { probe.rows << '${label}:start' }
		stop:     fn [mut probe, label] () ! { probe.rows << '${label}:stop' }
		snapshot: fn [label] () string { return label }
		emit:     fn [mut probe, label] (kind string, _fields map[string]string) {
			probe.rows << '${label}:${kind}'
		}
	}
}

fn test_provider_context_replacement_drives_adapter_and_all_snapshots() {
	mut old_probe := &LifecycleContextProbe{}
	mut new_probe := &LifecycleContextProbe{}
	mut app := &App{}
	app.register_provider_spec(ProviderSpec{
		name:          'test'
		enabled:       true
		has_runtime:   true
		provider:      DbProvider{}
		handler:       provider.NoopProviderCommandHandler{}
		runtime:       ProviderRuntimeAdapter{ provider: DbProvider{} }
		lifecycle_ctx: lifecycle_probe_context(mut old_probe, 'old')
	})
	mut spec := app.get_provider_spec('test') or { panic('missing spec') }
	assert spec.runtime_snapshot() == 'old'
	spec.lifecycle_ctx = lifecycle_probe_context(mut new_probe, 'new')
	app.register_provider_spec(spec)
	spec.start_runtime() or { panic(err) }
	assert spec.runtime_snapshot() == 'new'
	assert (app.provider_runtime_snapshot('test') or { panic('missing snapshot') }) == 'new'
	snapshots := app.admin_provider_runtimes_snapshot()
	assert snapshots.len == 1
	assert snapshots[0].snapshot == 'new'
	// Shutdown captures specs under the lock and calls the current context outside it.
	app.stop_all_providers()
	assert new_probe.rows == ['new:start', 'new:stop']
	assert old_probe.rows.len == 0
}

struct ContextReplacingProvider {
	replacement provider.RuntimeContext @[required]
}

fn (mut _ ContextReplacingProvider) init(mut _ctx provider.RuntimeContext) ! {}

fn (mut p ContextReplacingProvider) start(mut ctx provider.RuntimeContext) ! { ctx = p.replacement }

fn (mut _ ContextReplacingProvider) stop(mut ctx provider.RuntimeContext) ! { ctx.stop()! }

fn (mut _ ContextReplacingProvider) snapshot(mut ctx provider.RuntimeContext) string {
	return ctx.snapshot()
}

fn test_adapter_passes_context_mutation_back_to_its_caller() {
	mut probe := &LifecycleContextProbe{}
	mut ctx := provider.RuntimeContext.noop()
	mut adapter := ProviderRuntimeAdapter{
		provider: ContextReplacingProvider{ replacement: lifecycle_probe_context(mut probe, 'replacement') }
	}
	adapter.start(mut ctx) or { panic(err) }
	assert ctx.snapshot() == 'replacement'
	assert adapter.snapshot(mut ctx) == 'replacement'
	adapter.stop(mut ctx) or { panic(err) }
	assert probe.rows == ['replacement:stop']
}
