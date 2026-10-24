module main

import codex
import executor
import sync
import time
import upstream.transport

struct ErrorReleaseProbe {
mut:
	mu             sync.Mutex
	close_count    int
	delivered      chan transport.WorkerWebSocketUpstreamDispatchRequest = chan transport.WorkerWebSocketUpstreamDispatchRequest{cap: 16}
	dispatch_count int
	last_req       transport.WorkerWebSocketUpstreamDispatchRequest
}

struct ErrorReleaseExecutor {
mut:
	state &ErrorReleaseProbe @[required]
}

pub fn (e ErrorReleaseExecutor) kind() string {
	return 'vjsx'
}

pub fn (e ErrorReleaseExecutor) model() executor.LogicExecutorModel {
	return .embedded
}

pub fn (e ErrorReleaseExecutor) provider() string {
	return 'vjsx'
}

pub fn (e ErrorReleaseExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'vjsx'
		provider: 'vjsx'
		model:    executor.LogicExecutorModel.embedded.str()
	}
}

pub fn (e ErrorReleaseExecutor) warmup(mut app executor.AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e ErrorReleaseExecutor) close() {
	mut state := e.state
	state.mu.@lock()
	state.close_count++
	state.mu.unlock()
}

pub fn (e ErrorReleaseExecutor) dispatch_http(mut app executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ErrorReleaseExecutor) open_websocket_session(mut app executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ErrorReleaseExecutor) dispatch_stream(mut app executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ErrorReleaseExecutor) dispatch_mcp(mut app executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e ErrorReleaseExecutor) dispatch_websocket_upstream(mut app executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = app
	mut state := e.state
	state.mu.@lock()
	state.dispatch_count++
	state.last_req = req
	state.mu.unlock()
	state.delivered <- req
	return transport.WorkerWebSocketUpstreamDispatchResponse{
		mode:     'websocket_upstream'
		event:    'result'
		id:       req.id
		handled:  true
		commands: []transport.WorkerWebSocketUpstreamCommand{}
	}
}

pub fn (e ErrorReleaseExecutor) dispatch_websocket_event(mut app executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = app
	_ = frame
	return error('not_used')
}

fn test_codex_release_cancels_unclaimed_error_only_stream() {
	mut app := &App{}
	job := app.codex_queue_error_burst('main', 'released', 'old') or { panic('reserve') }
	defer { job.finish() }
	assert app.codex_clear_stream_targets('main', 'released')
	assert job.run.stopped()
	assert job.take().len == 0
	assert !app.codex_clear_stream_targets('main', 'released')
}

fn test_codex_release_with_routes_also_cancels_pending_error() {
	mut app := &App{}
	app.providers.codex.runtime.active_stream_id = 'released'
	job := app.codex_queue_error_burst('main', 'released', 'old') or { panic('reserve') }
	defer { job.finish() }
	assert app.codex_clear_stream_targets('main', 'released')
	assert app.codex_get_active_stream_id_for_instance('main') == ''
	assert job.run.stopped()
	assert job.take().len == 0
}

fn test_codex_error_release_normalizes_instance_and_preserves_other_jobs() {
	mut app := &App{}
	old := app.codex_queue_error_burst('default', 'released', 'old') or { panic('reserve') }
	other := app.codex_queue_error_burst('secondary', 'released', 'other-instance') or { panic('reserve') }
	keep := app.codex_queue_error_burst('main', 'keep', 'other-stream') or { panic('reserve') }
	defer {
		old.finish()
		other.finish()
		keep.finish()
	}
	_ = app.codex_clear_stream_targets('', 'released')
	assert old.run.stopped()
	assert old.take().len == 0
	assert other.take() == ['other-instance']
	assert keep.take() == ['other-stream']
}

fn test_codex_release_any_finds_error_jobs_without_runtime_instances() {
	mut app := &App{}
	main_job := app.codex_queue_error_burst('main', 'released', 'main') or { panic('reserve') }
	orphan := app.codex_queue_error_burst('unmaterialized', 'released', 'orphan') or { panic('reserve') }
	keep := app.codex_queue_error_burst('unmaterialized', 'keep', 'keep') or { panic('reserve') }
	defer {
		main_job.finish()
		orphan.finish()
		keep.finish()
	}
	assert 'unmaterialized' !in app.providers.codex.instances
	assert app.codex_clear_stream_targets_any('released')
	assert main_job.run.stopped()
	assert orphan.run.stopped()
	assert main_job.take().len == 0
	assert orphan.take().len == 0
	assert keep.take() == ['keep']
}

fn test_codex_reused_stream_gets_fresh_error_job_and_survives_old_finalizer() {
	mut app := &App{}
	old := app.codex_queue_error_burst('main', 'same', 'old') or { panic('reserve') }
	defer { old.finish() }
	_ = app.codex_clear_stream_targets('main', 'same')
	mut reserved := false
	if next := app.codex_queue_error_burst('main', 'same', 'new') {
		reserved = true
		defer { next.finish() }
		assert old.take().len == 0
		old.finish()
		old.finish()
		assert next.take() == ['new']
	}
	assert reserved
}

fn test_codex_cancelled_error_job_still_belongs_to_shutdown_join_until_finish() {
	mut app := &App{}
	job := app.codex_queue_error_burst('main', 'released', 'old') or { panic('reserve') }
	defer { job.finish() }
	_ = app.codex_clear_stream_targets('main', 'released')
	assert job.run.stopped()
	assert !job.run.finished()
	mut stopped := app.websocket.upstream_runs.request_pause('codex/')
	done := chan bool{cap: 1}
	spawn fn [mut stopped, done] () {
		stopped.wait()
		done <- true
	}()
	select {
		_ := <-done {
			panic('cancel released the unfinished job')
		}
		20 * time.millisecond {
		}
	}
	job.finish()
	select {
		_ := <-done {
		}
		time.second {
			panic('join did not finish')
		}
	}
	assert app.websocket.upstream_runs.resume_prefix('codex/')
}

fn test_codex_session_release_prevents_delayed_error_business_delivery() {
	mut app := &App{}
	mut probe := &ErrorReleaseProbe{}
	app.engines.primary.logic_executor = ErrorReleaseExecutor{ state: probe }
	defer {
		ctx := app.build_provider_context('codex')
		ctx.stop() or { panic(err) }
	}
	app.codex_queue_error_dispatch('main', 'released', '{"error":"old"}')
	_ = app.codex_clear_stream_targets('main', 'released')
	mut dispatched := false
	select {
		_ := <-probe.delivered {
			dispatched = true
		}
		time.second {
		}
	}
	assert !dispatched
}

fn test_codex_claimed_error_callback_retains_its_completion_ownership() {
	mut app := &App{}
	job := app.codex_queue_error_burst('main', 'claimed', 'accepted') or { panic('reserve') }
	defer { job.finish() }
	assert job.take() == ['accepted']
	assert !app.codex_clear_stream_targets('main', 'claimed')
	assert !job.run.stopped()
	assert !job.run.finished()
	job.finish()
	assert job.run.finished()
}

fn test_codex_empty_release_does_not_cancel_pending_errors() {
	mut app := &App{}
	job := app.codex_queue_error_burst('main', 'live', 'keep') or { panic('reserve') }
	defer { job.finish() }
	assert !app.codex_clear_stream_targets('main', '')
	assert !app.codex_clear_stream_targets_any('')
	assert job.take() == ['keep']
}
