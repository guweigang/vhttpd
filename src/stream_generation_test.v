module main

import executor
import worker
import upstream.transport
import net.unix
import os
import time
import json2 as json

fn generation_pool(path string, id int, inflight i64) &worker.WorkerState {
	return &worker.WorkerState{
		worker_backend: worker.WorkerBackendRuntime{
			autostart:       true
			sockets:         [path]
			read_timeout_ms: 1000
			managed_workers: [transport.ManagedWorker{ id: id, socket_path: path, next_retry_ts: time.now().unix_milli() + 60000, inflight_requests: inflight }]
		}
	}
}

fn generation_publish(mut app App, state &worker.WorkerState) {
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: state }
	app.mu.unlock()
}

fn generation_peer(mut listener unix.StreamListener, fail_next bool, done chan bool) {
	for event in ['open', 'next', 'close'] {
		mut conn := listener.accept() or { panic(err) }
		raw := worker.WorkerBackendFrameCodec.read(mut conn) or { panic(err) }
		req := json.decode[transport.StreamDispatchRequest](raw) or { panic(err) }
		assert req.event == event
		assert req.request_id == 'generation-request'
		assert req.trace_id == 'generation-trace'
		if event != 'open' {
			assert req.state['owner'] == 'original'
		}
		if event == 'close' {
			assert req.reason == if fail_next { 'transport_error' } else { 'completed' }
		}
		if event != 'next' || !fail_next {
			worker.WorkerBackendFrameCodec.write(mut conn, json.encode(transport.StreamDispatchResponse{
				handled: true
				done:    event != 'open'
				state:   {
					'owner': 'original'
				}
			})) or { panic(err) }
		}
		conn.close() or {}
	}
	done <- true
}

fn generation_worker_case(before_open bool, fail_next bool) {
	path := os.join_path(os.temp_dir(), 'vhttpd-generation-${os.getpid()}-${before_open}-${fail_next}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := generation_pool(path, 1, 0)
	mut replacement := generation_pool(path, 2, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	rt := app.build_stream_runtime_context()
	done := chan bool{cap: 1}
	spawn generation_peer(mut listener, fail_next, done)
	if before_open { generation_publish(mut app, replacement) }
	opened := rt.dispatch_open('GET', '/events', '', 'peer', 'generation-request', 'generation-trace', {}, {}) or { panic(err) }
	if !before_open { generation_publish(mut app, replacement) }
	mut state := opened.state.clone()
	mut reason := 'completed'
	if next := rt.dispatch_next('GET', '/events', 'peer', 'generation-request', 'generation-trace', {}, {}, state) {
		assert !fail_next
		state = next.state.clone()
	} else {
		assert fail_next
		reason = 'transport_error'
	}
	rt.dispatch_close('generation-request', 'generation-trace', state, reason) or { panic(err) }
	select {
		_ := <-done {
		}
		3 * time.second {
			assert false, 'stream peer did not finish'
		}
	}
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 3
	assert replacement.worker_backend.managed_workers[0].inflight_requests == 1
	assert replacement.worker_backend.managed_workers[0].served_requests == 0
}

fn test_stream_worker_context_retains_generation_before_and_after_open() {
	generation_worker_case(true, false)
	generation_worker_case(false, false)
}

fn test_stream_worker_failure_close_stays_on_original_generation() {
	generation_worker_case(false, true)
}

struct GenerationExecutor {
mut:
	label string
}

pub fn (e GenerationExecutor) kind() string {
	return 'vjsx'
}

pub fn (e GenerationExecutor) model() executor.LogicExecutorModel {
	return .embedded
}

pub fn (e GenerationExecutor) provider() string {
	return 'vjsx'
}

pub fn (e GenerationExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'vjsx'
		provider: 'vjsx'
		model:    executor.LogicExecutorModel.embedded.str()
	}
}

pub fn (e GenerationExecutor) warmup(mut app executor.AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e GenerationExecutor) close() {}

pub fn (e GenerationExecutor) dispatch_http(mut app executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e GenerationExecutor) open_websocket_session(mut app executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e GenerationExecutor) dispatch_stream(mut app executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return transport.StreamDispatchResponse{
		handled: true
		state:   {
			'owner': e.label
			'event': req.event
		}
	}
}

pub fn (e GenerationExecutor) dispatch_mcp(mut app executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e GenerationExecutor) dispatch_websocket_upstream(mut app executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return error('not_used')
}

pub fn (e GenerationExecutor) dispatch_websocket_event(mut app executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = app
	_ = frame
	return error('not_used')
}

fn test_stream_embedded_context_retains_executor_across_publication() {
	mut app := &App{ engines: EngineRuntime{ primary: &worker.WorkerState{ logic_executor: GenerationExecutor{ label: 'old' } } } }
	rt := app.build_stream_runtime_context()
	opened := rt.dispatch_open('GET', '/events', '', 'peer', 'id', 'trace', {}, {}) or { panic(err) }
	generation_publish(mut app, &worker.WorkerState{ logic_executor: GenerationExecutor{ label: 'new' } })
	next := rt.dispatch_next('GET', '/events', 'peer', 'id', 'trace', {}, {}, opened.state) or { panic(err) }
	closed := rt.dispatch_close('id', 'trace', next.state, 'completed') or { panic(err) }
	assert opened.state['owner'] == 'old'
	assert next.state['owner'] == 'old'
	assert closed.state['owner'] == 'old'
	fresh := app.build_stream_runtime_context()
	assert (fresh.dispatch_open('GET', '/events', '', 'peer', 'id2', 'trace', {}, {}) or { panic(err) }).state['owner'] == 'new'
}

fn test_stream_context_uses_http_selected_generation_before_publication() {
	mut app := &App{ engines: EngineRuntime{ primary: &worker.WorkerState{ logic_executor: GenerationExecutor{ label: 'selected' }, stream_dispatch: true } } }
	selected := app.engines.dispatch_selection('main')
	generation_publish(mut app, &worker.WorkerState{ logic_executor: GenerationExecutor{ label: 'replacement' } })
	rt := app.build_stream_runtime_context_for_state(selected.state)
	opened := rt.dispatch_open('GET', '/events', '', 'peer', 'id', 'trace', {}, {}) or { panic(err) }
	assert opened.state['owner'] == 'selected'
}
