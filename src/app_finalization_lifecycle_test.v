module main

import config
import executor
import os
import process_runtime
import provider
import server_lifecycle
import sync
import time
import worker

fn C.kill(int, int) int

@[heap]
struct AppFinalProbe {
mut:
	mu   sync.Mutex
	rows []string
}

fn (mut probe AppFinalProbe) record(row string) {
	probe.mu.@lock()
	probe.rows << row
	probe.mu.unlock()
}

fn (mut probe AppFinalProbe) snapshot() []string {
	probe.mu.@lock()
	defer { probe.mu.unlock() }
	return probe.rows.clone()
}

struct AppFinalExecutor {
	executor.DisabledLogicExecutor
	close_fn fn () @[required]
}

fn (_ AppFinalExecutor) kind() string { return 'custom_finalizer' }

fn (e AppFinalExecutor) close() { e.close_fn() }

fn app_final_fixture(root string, block bool, entered chan bool, release chan bool) (&App, server_lifecycle.ServerRuntimeConfig, &AppFinalProbe) {
	os.mkdir_all(root) or { panic(err) }
	entry := root + '/plugin.mts'
	os.write_file(entry, 'export function plugin(req) { return { ok: true }; }') or { panic(err) }
	mut probe := &AppFinalProbe{}
	mut app := &App{}
	app.app_build_cfg = server_lifecycle.AppRuntimeBuildConfig{ plan_listener_id: 'owner' }
	app.control_plane.event_log = root + '/events'
	plugins := {
		'test': config.PluginConfig{ kind: 'vjsx', app_entry: entry, runtime_profile: 'node', thread_count: 1 }
	}
	app.protocols.plugins.configs = plugins
	app.protocols.plugins.vjsx = build_vjsx_plugin_runtimes(plugins)
	plugin_executor := app.protocols.plugins.vjsx['test'] or { panic('missing plugin') }
	mut facade := app.as_facade()
	plugin_executor.warmup(mut facade) or { panic(err) }
	app.engines.primary.logic_executor = AppFinalExecutor{
		close_fn: fn [mut app, mut probe, block, entered, release] () {
			assert app.provider_names() == ['test'] // Also proves App.mu is not held.
			assert app.protocols.plugins.vjsx.len == 1
			probe.record('primary')
			if block {
				entered <- true
				_ := <-release
			}
		}
	}
	app.engines.additional['custom'] = &worker.WorkerState{
		logic_executor: AppFinalExecutor{
			close_fn: fn [mut probe] () {
				probe.record('additional')
			}
		}
	}
	ctx := provider.RuntimeContext{
		start:    fn () ! {}
		stop:     fn [mut app, mut probe, plugin_executor, root] () ! {
			assert app.protocols.plugins.vjsx.len == 0
			mut facade := app.as_facade()
			mut closed := false
			plugin_executor.warmup(mut facade) or {
				assert err.msg() == 'inproc_vjsx_executor_closed'
				closed = true
			}
			assert closed
			probe.record('provider')
			os.write_file(root + '/finalized', probe.snapshot().join(','))!
		}
		snapshot: fn () string { return '{}' }
		emit:     fn (_ string, _ map[string]string) {}
	}
	app.register_provider_spec(ProviderSpec{
		name:          'test'
		enabled:       true
		has_runtime:   true
		provider:      DbProvider{}
		handler:       provider.NoopProviderCommandHandler{}
		runtime:       ProviderRuntimeAdapter{ provider: DbProvider{} }
		lifecycle_ctx: ctx
	})
	base := executor.disabled_executor_lifecycle()
	lifecycle := executor.LogicExecutorLifecycle{
		...base
		stop_fn: fn [mut probe] (mut _ executor.LifecycleRuntimeContext) {
			probe.record('backend')
		}
	}
	cfg := server_lifecycle.ServerRuntimeConfig{ plan_listener_id: 'owner', pid_file: root + '/owner.pid', executor_plan: executor.LogicExecutorRuntimePlan{ executor: executor.DisabledLogicExecutor{}, lifecycle: lifecycle } }
	os.write_file(cfg.pid_file, '${os.getpid()}') or { panic(err) }
	return app, cfg, probe
}

fn app_final_root(label string) string {
	return os.join_path(os.temp_dir(), 'vhttpd-final-${os.getpid()}-${time.now().unix_micro()}-${label}')
}

fn app_final_wait(done chan bool) {
	select {
		_ := <-done {
		}
		5 * time.second {
			panic('App finalization deadline')
		}
	}
}

fn test_shared_app_finalizes_once_with_its_own_configuration_and_closes_real_plugin() {
	root := app_final_root('shared')
	defer { os.rmdir_all(root) or {} }
	mut app, cfg, mut probe := app_final_fixture(root, false, chan bool{cap: 1}, chan bool{cap: 1})
	base := executor.disabled_executor_lifecycle()
	bad := executor.LogicExecutorLifecycle{
		...base
		stop_fn: fn (mut _ executor.LifecycleRuntimeContext) {
			panic('alias lifecycle used')
		}
	}
	alias := server_lifecycle.ServerRuntimeConfig{ plan_listener_id: 'alias', pid_file: root + '/alias.pid', executor_plan: executor.LogicExecutorRuntimePlan{ executor: executor.DisabledLogicExecutor{}, lifecycle: bad } }
	os.write_file(alias.pid_file, 'alias') or { panic(err) }
	bindings := [RuntimeShutdownBinding{ app: app, cfg: alias },
		RuntimeShutdownBinding{ app: app, cfg: cfg }]
	shutdown_runtime_bindings(bindings) or { panic(err) }
	shutdown_runtime_bindings(bindings) or { panic(err) }
	assert probe.snapshot() == ['backend', 'primary', 'additional', 'provider']
	assert os.read_file(cfg.pid_file) or { panic(err) } == '${os.getpid()}'
	assert os.read_file(alias.pid_file) or { panic(err) } == 'alias'
	assert (os.read_lines(root + '/events') or { panic(err) }).filter(it.contains('"type":"server.stopped"')).len == 1
}

fn test_ordinary_and_signal_style_shutdown_join_the_same_in_progress_finalization() {
	root := app_final_root('race')
	defer { os.rmdir_all(root) or {} }
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	mut app, cfg, mut probe := app_final_fixture(root, true, entered, release)
	done := chan bool{cap: 2}
	spawn fn [mut app, cfg, done] () {
		shutdown_app_runtime(mut app, cfg)
		done <- true
	}()
	app_final_wait(entered)
	mut registry := &ActiveRuntimeRegistry{}
	registry.register(app, cfg)
	spawn fn [mut registry, done] () {
		registry.shutdown_apps() or { panic(err) }
		done <- true
	}()
	select {
		_ := <-done {
			panic('second closer overtook primary')
		}
		20 * time.millisecond {
		}
	}
	assert app.protocols.plugins.vjsx.len == 1
	release <- true
	app_final_wait(done)
	app_final_wait(done)
	assert probe.snapshot() == ['backend', 'primary', 'additional', 'provider']
}

fn testsuite_begin() {
	if os.args.len != 3 || os.args[1] != '--app-finalization-probe' { return }
	root := os.args[2]
	mut app, cfg, _ := app_final_fixture(root, false, chan bool{cap: 1}, chan bool{cap: 1})
	os.rm(cfg.pid_file) or { panic(err) }
	process_runtime.acquire_pid_files([cfg.pid_file]) or { panic(err) }
	register_active_runtime(app, cfg)
	register_active_runtime(app, cfg) // Shared listener registration.
	process_runtime.install_shutdown_signal_handler(vhttpd_shutdown_runtime) or { panic(err) }
	os.write_file(root + '/ready', 'ready') or { panic(err) }
	time.sleep(10 * time.second)
	exit(91)
}

fn app_final_signal(sig int) {
	root := app_final_root('signal')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut child := os.new_process(os.executable())
	child.set_args(['--app-finalization-probe', root])
	child.run()
	defer { child.close() }
	deadline := time.now().add(5 * time.second)
	for !os.exists(root + '/ready') && child.is_alive() && time.now() < deadline {
		time.sleep(time.millisecond)
	}
	if !os.exists(root + '/ready') {
		child.signal_kill()
		child.wait()
		assert false, 'child not ready'
		return
	}
	assert C.kill(child.pid, sig) == 0
	exit_deadline := time.now().add(5 * time.second)
	for child.is_alive() && time.now() < exit_deadline { time.sleep(time.millisecond) }
	if child.is_alive() { child.signal_kill() }
	child.wait()
	assert child.code == 128 + sig
	assert os.read_file(root + '/finalized') or { '' } == 'backend,primary,additional,provider'
	assert !os.exists(root + '/owner.pid')
}

fn test_sigterm_runs_app_finalizers_before_process_exit() { app_final_signal(15) }

fn test_sigint_runs_app_finalizers_before_process_exit() { app_final_signal(2) }

fn test_provider_stop_failure_does_not_skip_remaining_providers_or_repeat_finalizers() {
	root := app_final_root('provider-failure')
	defer { os.rmdir_all(root) or {} }
	mut app, cfg, mut probe := app_final_fixture(root, false, chan bool{cap: 1}, chan bool{cap: 1})
	mut original_spec := app.get_provider_spec('test') or { panic('missing provider') }
	original_context := original_spec.lifecycle_ctx
	ctx := provider.RuntimeContext{
		start:    fn () ! {}
		stop:     fn [mut probe, original_context] () ! {
			if !probe.snapshot().contains('failed-provider') {
				probe.record('failed-provider')
				return error('expected-stop-failure')
			}
			original_context.stop()!
		}
		snapshot: fn () string { return '{}' }
		emit:     fn (_ string, _ map[string]string) {}
	}
	original_spec.lifecycle_ctx = ctx
	app.register_provider_spec(original_spec)
	app.register_provider_spec(ProviderSpec{
		name:          'a-failing'
		enabled:       true
		has_runtime:   true
		provider:      DbProvider{}
		handler:       provider.NoopProviderCommandHandler{}
		runtime:       ProviderRuntimeAdapter{ provider: DbProvider{} }
		lifecycle_ctx: ctx
	})
	// This case has two providers; the executor's lock probe is covered separately.
	app.engines.primary.logic_executor = AppFinalExecutor{
		close_fn: fn [mut probe] () {
			probe.record('primary')
		}
	}
	shutdown_runtime_bindings([RuntimeShutdownBinding{ app: app, cfg: cfg }]) or { panic(err) }
	shutdown_app_runtime(mut app, cfg)
	assert probe.snapshot() == ['backend', 'primary', 'additional', 'failed-provider', 'provider']
	assert (os.read_file(root + '/events') or { panic(err) }).contains('provider.stop_failed')
}

fn test_finalization_waits_for_accepted_startup_and_rejects_late_start() {
	root := app_final_root('startup')
	defer { os.rmdir_all(root) or {} }
	mut app, cfg, mut probe := app_final_fixture(root, false, chan bool{cap: 1}, chan bool{cap: 1})
	assert app.lifecycle.shutdown.begin_start()
	done := chan bool{cap: 1}
	spawn fn [mut app, cfg, done] () {
		shutdown_app_runtime(mut app, cfg)
		done <- true
	}()
	deadline := time.now().add(time.second)
	for app.lifecycle.http.accepting() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	assert probe.snapshot().len == 0
	assert !app.lifecycle.shutdown.begin_start()
	app.lifecycle.shutdown.end_start()
	app_final_wait(done)
	assert probe.snapshot() == ['backend', 'primary', 'additional', 'provider']
	assert !app.lifecycle.shutdown.begin_start()
}
