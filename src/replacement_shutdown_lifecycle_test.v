module main

import config
import executor
import os
import runtime_plan
import server_lifecycle
import sync
import time
import worker

@[heap]
struct ReplacementProbe {
mut:
	mu      sync.Mutex
	warmups map[string]int
	closes  map[string]int
}

fn (mut probe ReplacementProbe) note(label string, closing bool) {
	probe.mu.@lock()
	defer { probe.mu.unlock() }
	if closing { probe.closes[label]++ } else { probe.warmups[label]++ }
}

fn (mut probe ReplacementProbe) counts(label string) (int, int) {
	probe.mu.@lock()
	defer { probe.mu.unlock() }
	return probe.warmups[label], probe.closes[label]
}

fn (mut probe ReplacementProbe) assert_counts(label string, warmups int, closes int) {
	actual_warmups, actual_closes := probe.counts(label)
	assert actual_warmups == warmups
	assert actual_closes == closes
}

struct ReplacementExecutor {
	executor.DisabledLogicExecutor
	label     string
	probe     &ReplacementProbe @[required]
	warmup_fn fn ()             @[required]
	close_fn  fn ()             @[required]
}

fn (e ReplacementExecutor) kind() string { return 'replacement_probe_${e.label}' }

fn (e ReplacementExecutor) warmup(mut _ executor.AppFacade) ! {
	mut probe := e.probe
	probe.note(e.label, false)
	e.warmup_fn()
}

fn (e ReplacementExecutor) close() {
	mut probe := e.probe
	probe.note(e.label, true)
	e.close_fn()
}

fn replacement_noop() {}

fn replacement_engine(probe &ReplacementProbe, label string, warmup_fn fn (), close_fn fn ()) EngineRuntime {
	return EngineRuntime{
		primary: &worker.WorkerState{
			worker_backend_mode: .disabled
			logic_executor:      ReplacementExecutor{ label: label, probe: probe, warmup_fn: warmup_fn, close_fn: close_fn }
		}
	}
}

fn replacement_prepared(engine EngineRuntime) RuntimePlanReplacementPreparedRuntime {
	return RuntimePlanReplacementPreparedRuntime{
		engines:           engine
		primary_lifecycle: executor.disabled_executor_lifecycle()
		listener:          'web'
	}
}

fn replacement_cfg() server_lifecycle.ServerRuntimeConfig {
	return server_lifecycle.ServerRuntimeConfig{
		executor_plan: executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
}

fn replacement_backend(probe &ReplacementProbe, label string) executor.LogicExecutorLifecycle {
	return executor.LogicExecutorLifecycle{
		name_fn:              fn [label] () string { return label }
		prepare_bootstrap_fn: fn (_ []string, _ config.VhttpdConfig, mut _ executor.ExecutorBootstrapState) ! {}
		start_fn:             fn [probe, label] (mut _ executor.LifecycleRuntimeContext) {
			mut current := probe
			current.note(label, false)
		}
		stop_fn:              fn [probe, label] (mut _ executor.LifecycleRuntimeContext) {
			mut current := probe
			current.note(label, true)
		}
	}
}

fn replacement_await(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('replacement lifecycle scope did not finish')
		}
	}
}

fn replacement_result(done chan string) string {
	select {
		result := <-done {
			return result
		}
		3 * time.second {
			panic('replacement did not finish')
		}
	}
	panic('missing replacement result')
}

fn replacement_pending(done chan bool) {
	select {
		_ := <-done {
			panic('shutdown passed an accepted replacement scope')
		}
		else {
		}
	}
}

fn replacement_wait_shutdown(mut app App) {
	deadline := time.now().add(3 * time.second)
	for app.lifecycle.http.accepting() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
}

fn replacement_spawn_shutdown(mut app App, done chan bool) {
	shutdown_runtime_bindings([RuntimeShutdownBinding{ app: &app, cfg: replacement_cfg() }]) or { panic(err) }
	done <- true
}

fn test_shutdown_joins_prepared_warmup_publication_and_old_engine_retirement() {
	mut probe := &ReplacementProbe{}
	warmup_entered := chan bool{cap: 1}
	warmup_release := chan bool{cap: 1}
	retire_entered := chan bool{cap: 1}
	retire_release := chan bool{cap: 1}
	mut app := &App{
		engines: replacement_engine(probe, 'old', replacement_noop, fn [retire_entered, retire_release] () {
			retire_entered <- true
			_ := <-retire_release
		})
	}
	mut prepared := replacement_prepared(replacement_engine(probe, 'next', fn [warmup_entered, warmup_release] () {
		warmup_entered <- true
		_ := <-warmup_release
	}, replacement_noop))
	applied := chan string{cap: 1}
	spawn fn [mut app, mut prepared, applied] () {
		app.apply_prepared_runtime_plan_replacement(mut prepared) or {
			applied <- err.msg()
			return
		}
		applied <- ''
	}()
	replacement_await(warmup_entered)
	stopped := chan bool{cap: 1}
	spawn replacement_spawn_shutdown(mut app, stopped)
	replacement_wait_shutdown(mut app)
	replacement_pending(stopped)
	probe.assert_counts('old', 0, 0)
	probe.assert_counts('next', 1, 0)
	warmup_release <- true
	replacement_await(retire_entered)
	replacement_pending(stopped)
	probe.assert_counts('next', 1, 0)
	// Old close callbacks can still acquire App.mu while shutdown waits.
	app.mu.@lock()
	app.mu.unlock()
	retire_release <- true
	assert replacement_result(applied) == ''
	replacement_await(stopped)
	probe.assert_counts('old', 0, 1)
	probe.assert_counts('next', 1, 1)
}

fn test_prepared_replacement_after_shutdown_never_starts_or_publishes_candidate() {
	mut probe := &ReplacementProbe{}
	mut app := &App{ engines: replacement_engine(probe, 'old', replacement_noop, replacement_noop) }
	shutdown_runtime_bindings([RuntimeShutdownBinding{ app: app, cfg: replacement_cfg() }]) or { panic(err) }
	mut prepared := replacement_prepared(replacement_engine(probe, 'late', replacement_noop, replacement_noop))
	if _ := app.apply_prepared_runtime_plan_replacement(mut prepared) {
		panic('replacement reopened a stopped App')
	} else {
		assert err.msg() == 'runtime_plan_replacement_app_stopping'
	}
	probe.assert_counts('old', 0, 1)
	probe.assert_counts('late', 0, 0)
	assert app.engines.primary_kind() == 'replacement_probe_old'
	// Rejection leaves this unstarted candidate with its preparing caller.
	mut candidate := prepared.engines
	candidate.stop(prepared.primary_lifecycle, app.build_engine_lifecycle_port())
}

fn test_lightweight_replacement_after_shutdown_preserves_published_plan() {
	mut app := &App{}
	app.protocols.runtime_plan_json = 'unchanged'
	assert app.lifecycle.shutdown.claim()
	if _ := app.apply_lightweight_runtime_plan(runtime_plan.RuntimePlan{}) {
		panic('lightweight replacement reopened a stopping App')
	} else {
		assert err.msg() == 'runtime_plan_replacement_app_stopping'
	}
	assert app.protocols.runtime_plan_json == 'unchanged'
	app.lifecycle.shutdown.finish('')
}

fn test_failed_replacement_closes_candidate_and_releases_shutdown_scope() {
	mut probe := &ReplacementProbe{}
	mut app := &App{ engines: replacement_engine(probe, 'old', replacement_noop, replacement_noop) }
	mut candidate := replacement_engine(probe, 'invalid', replacement_noop, replacement_noop)
	candidate.primary.worker_backend_mode = .required
	mut prepared := replacement_prepared(candidate)
	if _ := app.apply_prepared_runtime_plan_replacement(mut prepared) {
		panic('unready replacement was published')
	} else {
		assert err.msg() == 'runtime_plan_replacement_worker_sockets_empty:main'
	}
	probe.assert_counts('invalid', 1, 1)
	probe.assert_counts('old', 0, 0)
	stopped := chan bool{cap: 1}
	spawn replacement_spawn_shutdown(mut app, stopped)
	replacement_await(stopped)
	probe.assert_counts('old', 0, 1)
}

fn test_shutdown_joins_lightweight_plugin_retirement_before_engine_cleanup() {
	mut probe := &ReplacementProbe{}
	mut app := &App{ engines: replacement_engine(probe, 'engine', replacement_noop, replacement_noop) }
	app.protocols.plugins.publish({
		'test': config.PluginConfig{
			app_entry: os.join_path(@VMODROOT, 'examples/vjsx/hello-handler.mts')
		}
	})
	old := app.protocols.plugins.lookup('test') or { panic(err) }
	lane := old.select_next_lane() or { panic(err) }
	applied := chan string{cap: 1}
	spawn fn [mut app, applied] () {
		app.apply_lightweight_runtime_plan(runtime_plan.RuntimePlan{}) or {
			applied <- err.msg()
			return
		}
		applied <- ''
	}()
	deadline := time.now().add(3 * time.second)
	for {
		_ := app.protocols.plugins.lookup('test') or { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	stopped := chan bool{cap: 1}
	spawn replacement_spawn_shutdown(mut app, stopped)
	replacement_wait_shutdown(mut app)
	replacement_pending(stopped)
	probe.assert_counts('engine', 0, 0)
	old.release_lane(lane.id)
	assert replacement_result(applied) == ''
	replacement_await(stopped)
	probe.assert_counts('engine', 0, 1)
}

fn test_concurrent_replacements_retire_each_displaced_generation_once() {
	mut probe := &ReplacementProbe{}
	mut app := &App{ engines: replacement_engine(probe, 'initial', replacement_noop, replacement_noop) }
	entered := chan bool{cap: 12}
	release := chan bool{cap: 12}
	done := chan string{cap: 12}
	for index in 0 .. 12 {
		mut prepared := replacement_prepared(replacement_engine(probe, 'next_${index}', fn [entered, release] () {
			entered <- true
			_ := <-release
		}, replacement_noop))
		spawn fn [mut app, mut prepared, done] () {
			app.apply_prepared_runtime_plan_replacement(mut prepared) or {
				done <- err.msg()
				return
			}
			done <- ''
		}()
	}
	for _ in 0 .. 12 { replacement_await(entered) }
	for _ in 0 .. 12 { release <- true }
	for _ in 0 .. 12 {
		assert replacement_result(done) == ''
	}
	shutdown_runtime_bindings([RuntimeShutdownBinding{ app: app, cfg: replacement_cfg() }]) or { panic(err) }
	probe.assert_counts('initial', 0, 1)
	for index in 0 .. 12 {
		probe.assert_counts('next_${index}', 1, 1)
	}
}

fn test_replaced_engine_uses_its_own_backend_lifecycle_for_retirement_and_shutdown() {
	mut probe := &ReplacementProbe{}
	old_lifecycle := replacement_backend(probe, 'old_backend')
	next_lifecycle := replacement_backend(probe, 'next_backend')
	mut app := &App{ engines: replacement_engine(probe, 'old', replacement_noop, replacement_noop) }
	port := app.build_engine_lifecycle_port()
	mut facade := app.as_facade()
	app.engines.start(old_lifecycle, port, mut facade)
	base := replacement_prepared(replacement_engine(probe, 'next', replacement_noop, replacement_noop))
	mut prepared := RuntimePlanReplacementPreparedRuntime{ ...base, primary_lifecycle: next_lifecycle }
	app.apply_prepared_runtime_plan_replacement(mut prepared) or { panic(err) }
	probe.assert_counts('old_backend', 1, 1)
	probe.assert_counts('next_backend', 1, 0)
	// The App's original configuration still describes the previous backend.
	cfg := server_lifecycle.ServerRuntimeConfig{
		executor_plan: executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: old_lifecycle
		}
	}
	shutdown_runtime_bindings([RuntimeShutdownBinding{ app: app, cfg: cfg }]) or { panic(err) }
	probe.assert_counts('old_backend', 1, 1)
	probe.assert_counts('next_backend', 1, 1)
	probe.assert_counts('old', 1, 1)
	probe.assert_counts('next', 1, 1)
}
