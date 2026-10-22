module main

import sync
import time
import worker
import upstream.transport
import executor

fn workflow_pending(path string) RuntimePlanReplacementApplyResult {
	return RuntimePlanReplacementApplyResult{
		config_path: path
		status:      'drain_ready'
		strategy:    'engine_drain_required'
	}
}

fn workflow_await(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('workflow owner deadline')
		}
	}
}

fn test_busy_workflow_rejects_apply_finalize_cancel_without_touching_pending() {
	mut app := &App{}
	app.record_runtime_plan_replacement_apply(workflow_pending('original'))
	app.begin_runtime_plan_replacement_operation() or { panic(err) }
	defer { app.end_runtime_plan_replacement_operation() }
	applied := app.apply_runtime_plan_replacement('does-not-exist.toml') or { panic(err) }
	finalized := app.finalize_runtime_plan_replacement()
	cancelled := app.cancel_runtime_plan_replacement()
	assert applied.error == 'runtime_plan_replacement_busy'
	assert applied.config_path == 'does-not-exist.toml'
	assert finalized.error == 'runtime_plan_replacement_busy'
	assert cancelled.error == 'runtime_plan_replacement_busy'
	assert runtime_plan_replacement_apply_status_code(applied) == 409
	assert runtime_plan_replacement_finalize_status_code(finalized) == 409
	assert runtime_plan_replacement_cancel_status_code(cancelled) == 409
	assert app.replacement.pending.config_path == 'original'
	assert app.replacement.pending.active
}

fn test_failed_apply_releases_workflow_admission() {
	mut app := &App{}
	mut failed := false
	app.apply_runtime_plan_replacement('/__vhttpd_missing_workflow_config__.toml') or { failed = true }
	assert failed
	assert !app.replacement.operation_active
	app.begin_runtime_plan_replacement_operation() or { panic(err) }
	app.end_runtime_plan_replacement_operation()
	assert app.lifecycle.shutdown.claim()
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		app.lifecycle.shutdown.wait_started()
		done <- true
	}()
	workflow_await(done)
}

fn test_stopping_app_rejects_all_workflow_mutations() {
	mut app := &App{}
	app.record_runtime_plan_replacement_apply(workflow_pending('original'))
	assert app.lifecycle.shutdown.claim()
	applied := app.apply_runtime_plan_replacement('unused.toml') or { panic(err) }
	assert applied.error == 'runtime_plan_replacement_app_stopping'
	assert app.finalize_runtime_plan_replacement().error == 'runtime_plan_replacement_app_stopping'
	assert app.cancel_runtime_plan_replacement().error == 'runtime_plan_replacement_app_stopping'
	assert app.replacement.pending.config_path == 'original'
	assert app.replacement.pending.active
	drained := chan bool{cap: 1}
	spawn fn [mut app, drained] () {
		app.lifecycle.shutdown.wait_started()
		drained <- true
	}()
	workflow_await(drained)
}

fn test_shutdown_joins_workflow_before_it_releases_resources() {
	mut app := &App{}
	app.begin_runtime_plan_replacement_operation() or { panic(err) }
	assert app.lifecycle.shutdown.claim()
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		app.lifecycle.shutdown.wait_started()
		done <- true
	}()
	select {
		_ := <-done {
			panic('shutdown passed active workflow')
		}
		20 * time.millisecond {
		}
	}
	// Rejected contenders must not release the accepted operation's lifecycle count.
	assert app.cancel_runtime_plan_replacement().error == 'runtime_plan_replacement_app_stopping'
	app.end_runtime_plan_replacement_operation()
	workflow_await(done)
	assert !app.replacement.operation_active
}

fn test_cancelled_pending_cannot_be_restored_by_old_refresh() {
	mut app := &App{}
	app.record_runtime_plan_replacement_apply(workflow_pending('same'))
	old := app.replacement.pending
	generation := app.replacement.pending_generation
	assert app.cancel_runtime_plan_replacement().cancelled
	refreshed := app.publish_pending_runtime_plan_refresh(generation, old)
	assert !refreshed.active
	assert !app.replacement.pending.active
}

fn test_identical_pending_replacement_rejects_prior_generation_refresh() {
	mut app := &App{}
	app.record_runtime_plan_replacement_apply(workflow_pending('same'))
	old := app.replacement.pending
	generation := app.replacement.pending_generation
	assert app.cancel_runtime_plan_replacement().cancelled
	app.record_runtime_plan_replacement_apply(workflow_pending('same'))
	current := app.replacement.pending
	refreshed := app.publish_pending_runtime_plan_refresh(generation, RuntimePlanReplacementPendingSnapshot{
		...old
		ready:         false
		refresh_error: 'stale'
	})
	assert refreshed.ready == current.ready
	assert refreshed.refresh_error == ''
	assert app.replacement.pending_generation != generation
	fresh := app.publish_pending_runtime_plan_refresh(app.replacement.pending_generation, RuntimePlanReplacementPendingSnapshot{
		...current
		ready: false
	})
	assert !fresh.ready
}

fn test_concurrent_workflow_claims_have_one_owner_and_release_failed_claims() {
	mut app := &App{}
	mut barrier := sync.new_waitgroup()
	barrier.add(8)
	claimed := chan bool{cap: 8}
	release := chan bool{cap: 1}
	done := chan bool{cap: 8}
	for _ in 0 .. 8 {
		spawn fn [mut app, mut barrier, claimed, release, done] () {
			app.begin_runtime_plan_replacement_operation() or {
				assert err.msg() == 'runtime_plan_replacement_busy'
				claimed <- false
				barrier.done()
				done <- true
				return
			}
			claimed <- true
			barrier.done()
			_ := <-release
			app.end_runtime_plan_replacement_operation()
			done <- true
		}()
	}
	barrier.wait()
	mut owners := 0
	for _ in 0 .. 8 { if <-claimed { owners++ } }
	assert owners == 1
	release <- true
	for _ in 0 .. 8 { workflow_await(done) }
	app.begin_runtime_plan_replacement_operation() or { panic(err) }
	app.end_runtime_plan_replacement_operation()
	assert app.lifecycle.shutdown.claim()
	drained := chan bool{cap: 1}
	spawn fn [mut app, drained] () {
		app.lifecycle.shutdown.wait_started()
		drained <- true
	}()
	workflow_await(drained)
}

fn test_public_cancel_owns_resume_until_completion_and_shutdown_waits() {
	mut app := &App{
		engines: EngineRuntime{
			primary: &worker.WorkerState{
				logic_executor: executor.SocketWorkerExecutor{}
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [transport.ManagedWorker{ socket_path: '/tmp/workflow-owned.sock', draining: true }]
				}
			}
		}
	}
	app.record_runtime_plan_replacement_apply(RuntimePlanReplacementApplyResult{
		...workflow_pending('original')
		preview: RuntimePlanReplacementPreview{ drain_engines: ['main'] }
	})
	app.engines.primary.mu.@lock()
	cancelled := chan bool{cap: 1}
	spawn fn [mut app, cancelled] () {
		result := app.cancel_runtime_plan_replacement()
		assert result.cancelled
		assert result.resumed.len == 1
		assert result.resumed[0].draining_count == 0
		cancelled <- true
	}()
	deadline := time.now().add(3 * time.second)
	for {
		app.mu.@lock()
		active := app.replacement.operation_active
		app.mu.unlock()
		if active { break }
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	// The first cancel is blocked on worker accounting, not on App.mu.
	assert app.finalize_runtime_plan_replacement().error == 'runtime_plan_replacement_busy'
	assert app.cancel_runtime_plan_replacement().error == 'runtime_plan_replacement_busy'
	assert app.lifecycle.shutdown.claim()
	stopped := chan bool{cap: 1}
	spawn fn [mut app, stopped] () {
		app.lifecycle.shutdown.wait_started()
		stopped <- true
	}()
	select {
		_ := <-stopped {
			panic('shutdown passed unfinished resume')
		}
		20 * time.millisecond {
		}
	}
	app.engines.primary.mu.unlock()
	workflow_await(cancelled)
	workflow_await(stopped)
	assert !app.replacement.pending.active
	assert !app.replacement.operation_active
}
