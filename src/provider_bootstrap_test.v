module main

import command
import upstream.transport
import executor
import provider
import os

@[heap]
struct BootstrapProbe {
mut:
	rows []string
}

fn bootstrap_test_context(mut probe BootstrapProbe, label string) provider.RuntimeContext {
	return provider.RuntimeContext{
		start:    fn () ! {}
		stop:     fn [mut probe, label] () ! { probe.rows << '${label}:stop' }
		snapshot: fn [label] () string { return label }
		emit:     fn (_kind string, _fields map[string]string) {}
	}
}

@[heap]
struct BootstrapTestProvider {
mut:
	app     &App            @[required]
	probe   &BootstrapProbe @[required]
	failure string
}

fn (mut p BootstrapTestProvider) init(mut ctx provider.RuntimeContext) ! {
	mut registered := p.app.get_provider_spec('bootstrap-test') or { panic('missing spec at init') }
	assert registered.has_handler && registered.has_runtime
	assert registered.runtime_driver == 'test-driver'
	assert registered.command_matchers.len == 1
	assert registered.runtime_snapshot() == 'initial'
	p.probe.rows << 'init'
	ctx = bootstrap_test_context(mut p.probe, 'initialized')
	if p.failure == 'init' { return error('init failed') }
}

fn (mut p BootstrapTestProvider) start(mut ctx provider.RuntimeContext) ! {
	mut registered := p.app.get_provider_spec('bootstrap-test') or { panic('missing spec at start') }
	assert registered.runtime_snapshot() == 'initialized'
	p.probe.rows << 'start'
	ctx = bootstrap_test_context(mut p.probe, 'started')
	if p.failure == 'start' { return error('start failed') }
}

fn (mut _ BootstrapTestProvider) stop(mut ctx provider.RuntimeContext) ! { ctx.stop()! }

fn (mut _ BootstrapTestProvider) snapshot(mut ctx provider.RuntimeContext) string {
	return ctx.snapshot()
}

fn test_bootstrap_publishes_complete_spec_and_context_on_success_and_failure() {
	for failure in ['', 'init', 'start'] {
		event_log := os.join_path(os.temp_dir(), 'vhttpd-bootstrap-${os.getpid()}-${failure}.ndjson')
		os.rm(event_log) or {}
		mut app := &App{ control_plane: ControlPlaneRuntime{ event_log: event_log } }
		mut probe := &BootstrapProbe{}
		mut p := &BootstrapTestProvider{ app: app, probe: probe, failure: failure }
		mut spec := ProviderSpec{
			name:             'bootstrap-test'
			enabled:          true
			has_handler:      true
			has_runtime:      true
			runtime_driver:   'test-driver'
			command_matchers: [provider.CommandMatcher{ kind: .prefix, value: 'test.' }]
			provider:         p
			handler:          provider.NoopProviderCommandHandler{}
			runtime:          ProviderRuntimeAdapter{ provider: p }
			lifecycle_ctx:    bootstrap_test_context(mut probe, 'initial')
		}
		app.register_and_start_provider(mut spec)
		mut registered := app.get_provider_spec('bootstrap-test') or { panic('missing final spec') }
		expected := if failure == 'init' { 'initialized' } else { 'started' }
		assert registered.runtime_snapshot() == expected
		assert spec.runtime_snapshot() == expected
		assert 'bootstrap-test' in app.providers.registry.registry
		assert probe.rows == if failure == 'init' { ['init'] } else { ['init', 'start'] }
		if failure != '' {
			log := os.read_file(event_log) or { panic(err) }
			assert log.contains('provider.${failure}_failed')
			assert log.contains('bootstrap-test')
			assert log.contains('${failure} failed')
		}
		app.stop_all_providers()
		assert probe.rows.last() == '${expected}:stop'
		os.rm(event_log) or {}
	}
}

fn test_provider_noop_handlers_and_runtime_smoke() {
	// Ensure NoopProviderCommandHandler and NoopProviderRuntime behave as expected
	h := provider.NoopProviderCommandHandler{}
	mut r := NoopProviderRuntime{}

	// execute should return (false, '')
	cmd := transport.WorkerWebSocketUpstreamCommand{}
	normalized := command.NormalizedCommand.from_worker_command(cmd)
	mut snap := executor.WebSocketUpstreamCommandActivity{}
	ok, msg := h.execute(cmd, normalized, mut snap)
	assert ok == false
	assert msg == ''

	// runtime snapshot and lifecycle hooks should be callable
	mut ctx := provider.RuntimeContext.noop()
	_ = r.snapshot(mut ctx)
	r.start(mut ctx) or { panic(err) }
	r.stop(mut ctx) or { panic(err) }
}
