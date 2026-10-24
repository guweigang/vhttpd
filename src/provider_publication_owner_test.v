module main

import provider
import os
import time

@[heap]
struct PublicationProviderProbe {
mut:
	starts int
	stops  []string
}

fn publication_provider_context(label string, probe &PublicationProviderProbe) provider.RuntimeContext {
	mut owned := unsafe { probe }
	return provider.RuntimeContext{
		start:    fn () ! {}
		stop:     fn [mut owned, label] () ! { owned.stops << label }
		snapshot: fn [label] () string { return label }
		emit:     fn (_ string, _ map[string]string) {}
	}
}

@[heap]
struct PublicationProvider {
mut:
	app      &App                      @[required]
	probe    &PublicationProviderProbe @[required]
	phase    string
	failure  string
	withdraw bool
	entered  chan bool = chan bool{cap: 1}
	release  chan bool = chan bool{cap: 1}
}

fn publication_replacement_spec(probe &PublicationProviderProbe) ProviderSpec {
	return ProviderSpec{
		name:           'publication'
		enabled:        true
		has_runtime:    true
		runtime_driver: 'replacement'
		provider:       DbProvider{}
		handler:        provider.NoopProviderCommandHandler{}
		runtime:        ProviderRuntimeAdapter{ provider: DbProvider{} }
		lifecycle_ctx:  publication_provider_context('replacement', probe)
	}
}

fn (mut p PublicationProvider) change(phase string) {
	if p.phase == 'settings' && phase == 'init' {
		p.app.mu.@lock()
		p.app.providers.apply_provider_runtime_settings(provider.ProviderRuntimeSettings{
			runtime_drivers: {
				'publication': 'refreshed'
			}
		})
		p.app.mu.unlock()
		return
	}
	if p.phase != phase { return }
	if p.withdraw {
		p.app.stop_all_providers()
	} else {
		p.app.register_provider_spec(publication_replacement_spec(p.probe))
	}
}

fn (mut p PublicationProvider) init(mut ctx provider.RuntimeContext) ! {
	if p.phase == 'blocked' {
		p.entered <- true
		_ := <-p.release
	}
	p.change('init')
	ctx = publication_provider_context('initialized', p.probe)
	if p.failure == 'init' { return error('initialization failed') }
}

fn (mut p PublicationProvider) start(mut ctx provider.RuntimeContext) ! {
	p.probe.starts++
	p.change('start')
	ctx = publication_provider_context('started', p.probe)
	if p.failure == 'start' { return error('start failed') }
}

fn (mut _ PublicationProvider) stop(mut ctx provider.RuntimeContext) ! { ctx.stop()! }

fn (mut _ PublicationProvider) snapshot(mut ctx provider.RuntimeContext) string {
	return ctx.snapshot()
}

fn publication_original_spec(p &PublicationProvider) ProviderSpec {
	return ProviderSpec{
		name:           'publication'
		enabled:        true
		has_runtime:    true
		runtime_driver: 'original'
		provider:       p
		handler:        provider.NoopProviderCommandHandler{}
		runtime:        ProviderRuntimeAdapter{ provider: p }
		lifecycle_ctx:  publication_provider_context('initial', p.probe)
	}
}

fn publication_test_app(label string) &App {
	return &App{ control_plane: ControlPlaneRuntime{ event_log: os.join_path(os.temp_dir(), 'provider-publication-${os.getpid()}-${label}.ndjson') } }
}

fn test_replacement_during_init_preserves_new_spec_and_cleans_original_context() {
	for failure in ['', 'init'] {
		mut app := publication_test_app('init-${failure}')
		probe := &PublicationProviderProbe{}
		p := &PublicationProvider{ app: app, probe: probe, phase: 'init', failure: failure }
		mut spec := publication_original_spec(p)
		app.register_and_start_provider(mut spec)
		mut current := app.get_provider_spec('publication') or { panic('missing replacement') }
		assert current.runtime_driver == 'replacement'
		assert current.runtime_snapshot() == 'replacement'
		assert probe.starts == 0
		assert probe.stops == ['initialized']
		app.stop_all_providers()
		assert probe.stops == ['initialized', 'replacement']
	}
}

fn test_replacement_during_start_preserves_new_spec_and_cleans_completed_context() {
	for failure in ['', 'start'] {
		mut app := publication_test_app('start-${failure}')
		probe := &PublicationProviderProbe{}
		p := &PublicationProvider{ app: app, probe: probe, phase: 'start', failure: failure }
		mut spec := publication_original_spec(p)
		app.register_and_start_provider(mut spec)
		mut current := app.get_provider_spec('publication') or { panic('missing replacement') }
		assert current.runtime_driver == 'replacement'
		assert current.runtime_snapshot() == 'replacement'
		assert probe.starts == 1
		assert probe.stops == ['started']
	}
}

fn test_reentrant_stop_revokes_init_publication_without_stopping_unfinished_context() {
	mut app := publication_test_app('revoke-init')
	probe := &PublicationProviderProbe{}
	p := &PublicationProvider{ app: app, probe: probe, phase: 'init', withdraw: true }
	mut spec := publication_original_spec(p)
	app.register_and_start_provider(mut spec)
	assert probe.starts == 0
	assert probe.stops == ['initialized']
	mut current := app.get_provider_spec('publication') or { panic('missing diagnostic spec') }
	assert current.runtime_snapshot() == 'initial'
}

fn test_reentrant_stop_revokes_start_completion_without_double_cleanup() {
	mut app := publication_test_app('revoke-start')
	probe := &PublicationProviderProbe{}
	p := &PublicationProvider{ app: app, probe: probe, phase: 'start', withdraw: true }
	mut spec := publication_original_spec(p)
	app.register_and_start_provider(mut spec)
	assert probe.starts == 1
	assert probe.stops == ['started']
	mut current := app.get_provider_spec('publication') or { panic('missing diagnostic spec') }
	assert current.runtime_snapshot() == 'initialized'
}

fn test_async_init_revocation_keeps_cleanup_with_original_completion() {
	mut app := publication_test_app('async')
	probe := &PublicationProviderProbe{}
	p := &PublicationProvider{ app: app, probe: probe, phase: 'blocked' }
	job := spawn fn [mut app, p] () {
		mut spec := publication_original_spec(p)
		app.register_and_start_provider(mut spec)
	}()
	_ := <-p.entered
	app.stop_all_providers()
	stopped_while_blocked := probe.stops.clone()
	app.register_provider_spec(publication_replacement_spec(probe))
	p.release <- true
	job.wait()
	assert stopped_while_blocked.len == 0
	assert probe.starts == 0
	assert probe.stops == ['initialized']
	mut current := app.get_provider_spec('publication') or { panic('missing replacement') }
	assert current.runtime_snapshot() == 'replacement'
}

fn test_provider_start_after_shutdown_claim_does_not_publish_or_run_callbacks() {
	mut app := publication_test_app('late')
	probe := &PublicationProviderProbe{}
	p := &PublicationProvider{ app: app, probe: probe }
	mut spec := publication_original_spec(p)
	assert app.lifecycle.shutdown.claim()
	app.register_and_start_provider(mut spec)
	assert app.get_provider_spec('publication') == none
	assert probe.starts == 0
	assert probe.stops.len == 0
}

fn test_bootstrap_completion_preserves_concurrent_runtime_configuration_metadata() {
	mut app := publication_test_app('settings')
	probe := &PublicationProviderProbe{}
	p := &PublicationProvider{ app: app, probe: probe, phase: 'settings' }
	mut spec := publication_original_spec(p)
	app.register_and_start_provider(mut spec)
	mut current := app.get_provider_spec('publication') or { panic('missing spec') }
	assert current.runtime_driver == 'refreshed'
	assert current.runtime_snapshot() == 'started'
	assert probe.starts == 1
	assert probe.stops.len == 0
	app.stop_all_providers()
	assert probe.stops == ['started']
}

fn test_provider_stop_revocation_is_once_per_registration_and_allows_fresh_registration() {
	mut app := publication_test_app('once')
	probe := &PublicationProviderProbe{}
	app.register_provider_spec(publication_replacement_spec(probe))
	app.stop_all_providers()
	app.stop_all_providers()
	assert probe.stops == ['replacement']
	app.register_provider_spec(publication_replacement_spec(probe))
	app.stop_all_providers()
	assert probe.stops == ['replacement', 'replacement']
}

fn test_shutdown_start_join_waits_for_revoked_callback_and_its_final_cleanup() {
	mut app := publication_test_app('join')
	probe := &PublicationProviderProbe{}
	p := &PublicationProvider{ app: app, probe: probe, phase: 'blocked' }
	job := spawn fn [mut app, p] () {
		mut spec := publication_original_spec(p)
		app.register_and_start_provider(mut spec)
	}()
	_ := <-p.entered
	assert app.lifecycle.shutdown.claim()
	app.stop_all_providers()
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		app.lifecycle.shutdown.wait_started()
		done <- true
	}()
	mut premature := false
	select {
		_ := <-done {
			premature = true
		}
		10 * time.millisecond {
		}
	}
	p.release <- true
	job.wait()
	if !premature {
		select {
			_ := <-done {
			}
			time.second {
				panic('startup join stuck')
			}
		}
	}
	assert !premature
	assert probe.starts == 0
	assert probe.stops == ['initialized']
}

@[heap]
struct BorrowedContextReplacingProvider {
mut:
	app &App @[required]
}

fn (mut p BorrowedContextReplacingProvider) init(mut _ctx provider.RuntimeContext) ! {
	p.app.register_provider_spec(ProviderSpec{
		name:          'codex'
		enabled:       true
		has_runtime:   true
		provider:      CodexProvider{}
		handler:       provider.NoopProviderCommandHandler{}
		runtime:       NoopProviderRuntime{}
		lifecycle_ctx: provider.RuntimeContext.noop()
	})
}

fn (mut _ BorrowedContextReplacingProvider) start(mut _ctx provider.RuntimeContext) ! {
	panic('retired init started')
}

fn (mut _ BorrowedContextReplacingProvider) stop(mut ctx provider.RuntimeContext) ! { ctx.stop()! }

fn (mut _ BorrowedContextReplacingProvider) snapshot(mut _ctx provider.RuntimeContext) string {
	return '{}'
}

fn test_retired_app_context_does_not_pause_network_resources_borrowed_by_replacement() {
	mut app := publication_test_app('borrowed')
	mut p := &BorrowedContextReplacingProvider{ app: app }
	mut spec := ProviderSpec{
		name:          'codex'
		enabled:       true
		has_runtime:   true
		provider:      p
		handler:       provider.NoopProviderCommandHandler{}
		runtime:       ProviderRuntimeAdapter{ provider: p }
		lifecycle_ctx: app.build_provider_context('codex')
	}
	app.register_and_start_provider(mut spec)
	mut run := app.websocket.upstream_runs.reserve('codex/replacement') or { panic('retired context paused replacement network') }
	app.websocket.upstream_runs.release('codex/replacement', mut run)
	assert app.get_provider_spec('codex') != none
}
