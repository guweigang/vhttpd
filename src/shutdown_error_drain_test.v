module main

import executor
import http_runtime
import server_lifecycle
import sync
import time
import veb

@[heap]
struct ShutdownDrainProbe {
mut:
	mu   sync.Mutex
	rows []string
}

fn (mut probe ShutdownDrainProbe) record(row string) {
	probe.mu.@lock()
	defer { probe.mu.unlock() }
	probe.rows << row
}

fn (mut probe ShutdownDrainProbe) snapshot() []string {
	probe.mu.@lock()
	defer { probe.mu.unlock() }
	return probe.rows.clone()
}

struct ShutdownDrainExecutor {
	executor.DisabledLogicExecutor
	close_fn fn () @[required]
}

fn (_ ShutdownDrainExecutor) kind() string { return 'shutdown_drain_probe' }

fn (e ShutdownDrainExecutor) close() { e.close_fn() }

fn shutdown_error_app(label string, mut probe ShutdownDrainProbe) &App {
	mut app := &App{}
	app.engines.primary.logic_executor = ShutdownDrainExecutor{
		close_fn: fn [mut probe, label] () { probe.record(label) }
	}
	return app
}

fn shutdown_error_cfg() server_lifecycle.ServerRuntimeConfig {
	return server_lifecycle.ServerRuntimeConfig{
		executor_plan: executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
}

fn shutdown_error_inject(mut owner http_runtime.Owner) {
	mut run := owner.reserve('unsupported-native') or { panic('reserve') }
	owner.serve(mut run, fn [mut owner] () {
		owner.publish(&veb.Server{})
		owner.ready()
	})
}

fn shutdown_error_hold(mut owner http_runtime.Owner, mut run http_runtime.Run, entered chan bool, release chan bool) {
	owner.serve(mut run, fn [entered, release] () {
		entered <- true
		_ := <-release
	})
}

fn shutdown_error_call(bindings []RuntimeShutdownBinding, done chan string) {
	shutdown_runtime_bindings(bindings) or {
		done <- err.msg()
		return
	}
	done <- ''
}

fn test_failed_http_app_does_not_skip_healthy_app_drain_or_finalizers() {
	mut probe := &ShutdownDrainProbe{}
	mut failed := shutdown_error_app('failed', mut probe)
	mut healthy := shutdown_error_app('healthy', mut probe)
	shutdown_error_inject(mut failed.lifecycle.http)
	mut run := healthy.lifecycle.http.reserve('held') or { panic('reserve') }
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	serving_thread := spawn shutdown_error_hold(mut healthy.lifecycle.http, mut run, entered, release)
	_ := <-entered
	cfg := shutdown_error_cfg()
	bindings := [RuntimeShutdownBinding{ app: failed, cfg: cfg },
		RuntimeShutdownBinding{ app: healthy, cfg: cfg }]
	done := chan string{cap: 1}
	caller := spawn shutdown_error_call(bindings, done)
	mut early := false
	mut failure := ''
	select {
		value := <-done {
			early = true
			failure = value
		}
		20 * time.millisecond {
		}
	}
	before_release := probe.snapshot()
	release <- true
	serving_thread.wait()
	caller.wait()
	if !early { failure = <-done }
	assert !early
	assert before_release.len == 0
	assert failure.contains('not available with SSL')
	assert probe.snapshot() == ['healthy']
	// A failed ingress retains its dependencies; a healthy App is fully stopped.
	healthy.lifecycle.shutdown.wait_stopped() or { panic(err) }
	assert healthy.transport.cache.listener_owner.reserve() == none
	mut repeated := ''
	shutdown_runtime_bindings(bindings) or { repeated = err.msg() }
	assert repeated == failure
	assert probe.snapshot() == ['healthy']
}

fn test_http_error_still_joins_admin_and_websocket_ingresses() {
	mut probe := &ShutdownDrainProbe{}
	mut app := shutdown_error_app('retained', mut probe)
	shutdown_error_inject(mut app.lifecycle.http)
	mut admin := app.lifecycle.admin_http.reserve('held-admin') or { panic('reserve') }
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	serving_thread := spawn shutdown_error_hold(mut app.lifecycle.admin_http, mut admin, entered, release)
	_ := <-entered
	mut websocket := app.websocket.state.ingress.reserve() or { panic('websocket reserve') }
	done := chan string{cap: 1}
	caller := spawn shutdown_error_call([RuntimeShutdownBinding{ app: app, cfg: shutdown_error_cfg() }], done)
	mut early := false
	mut failure := ''
	select {
		value := <-done {
			early = true
			failure = value
		}
		20 * time.millisecond {
		}
	}
	release <- true
	serving_thread.wait()
	mut skipped_websocket := false
	if !early {
		select {
			value := <-done {
				skipped_websocket = true
				failure = value
			}
			20 * time.millisecond {
			}
		}
	}
	websocket.finish()
	caller.wait()
	if !early && !skipped_websocket { failure = <-done }
	assert !early
	assert !skipped_websocket
	assert failure.contains('not available with SSL')
	assert probe.snapshot().len == 0
}
