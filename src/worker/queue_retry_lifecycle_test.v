module worker

import time
import os
import net.unix
import upstream.transport

@[heap]
struct RetryQueueProbe {
mut:
	selects  int
	releases int
	events   int
}

fn retry_queue_context(probe &RetryQueueProbe, failure string) ConnectorContext {
	mut captured := probe
	return ConnectorContext{
		connect_fn:       unix.connect_stream
		select_socket_fn: fn [mut captured, failure] () !string {
			captured.selects++
			return error(failure)
		}
		release_fn:       fn [mut captured] (_ string) { captured.releases++ }
		emit_fn:          fn [mut captured] (_ string, _ map[string]string) { captured.events++ }
	}
}

fn test_connect_selected_does_not_retry_terminal_queue_errors() {
	for message in ['worker queue full', 'worker queue timeout'] {
		mut probe := &RetryQueueProbe{}
		if _, _ := ConnectorRuntime.connect_selected(retry_queue_context(probe, message)) {
			assert false
		} else {
			assert err.msg() == message
		}
		assert probe.selects == 1
		assert probe.releases == 0
		assert probe.events == 0
	}
}

fn test_connect_selected_has_one_selection_retry_budget() {
	mut probe := &RetryQueueProbe{}
	if _, _ := ConnectorRuntime.connect_selected(retry_queue_context(probe, 'worker unavailable')) {
		assert false
	} else {
		assert err.msg() == 'worker unavailable'
	}
	assert probe.selects == 10
	assert probe.releases == 0
	assert probe.events == 0
}

fn retry_queue_busy(timeout int, poll int) &WorkerState {
	return &WorkerState{
		worker_backend: WorkerBackendRuntime{
			sockets:          ['queue-owned.sock']
			autostart:        true
			queue_capacity:   1
			queue_timeout_ms: timeout
			queue_poll_ms:    poll
			managed_workers:  [transport.ManagedWorker{
				socket_path:       'queue-owned.sock'
				inflight_requests: 1
				next_retry_ts:     9_223_372_036_854
			}]
		}
	}
}

fn retry_queue_select(mut state WorkerState, result chan string) {
	socket := state.select_socket_queued(LifecyclePort{}, 'test') or {
		result <- err.msg()
		return
	}
	result <- socket
}

fn retry_queue_result(result chan string) string {
	mut received := ''
	select {
		value := <-result {
			received = value
		}
		3 * time.second {
			panic('queue selection did not finish')
		}
	}
	return received
}

fn test_expired_poll_never_leases_a_worker_that_becomes_idle_later() {
	mut state := retry_queue_busy(30, 200)
	result := chan string{cap: 1}
	spawn retry_queue_select(mut state, result)
	deadline := time.now().add(3 * time.second)
	for {
		state.mu.@lock()
		queued := state.worker_backend.queue_waiting_requests > 0
		state.mu.unlock()
		if queued { break }
		select {
			value := <-result {
				assert value == 'worker queue timeout'
				assert state.request_released('queue-owned.sock')
				return
			}
			else {
			}
		}
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	time.sleep(60 * time.millisecond)
	assert state.request_released('queue-owned.sock')
	assert retry_queue_result(result) == 'worker queue timeout'
	assert state.worker_backend.queue_waiting_requests == 0
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 0
	assert state.stat_queue_waits_total == 1
	assert state.stat_queue_timeouts_total == 1
}

fn retry_queue_wait_entered(mut state WorkerState, result chan string) {
	deadline := time.now().add(3 * time.second)
	for {
		state.mu.@lock()
		queued := state.worker_backend.queue_waiting_requests > 0
		state.mu.unlock()
		if queued { return }
		select {
			value := <-result {
				panic('selection returned before fixture barrier: ${value}')
			}
			else {
			}
		}
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
}

fn test_late_selection_returns_its_lease_without_serving_a_request() {
	mut state := retry_queue_busy(200, 10)
	result := chan string{cap: 1}
	spawn retry_queue_select(mut state, result)
	retry_queue_wait_entered(mut state, result)
	// Readiness may wait for worker accounting. Make the worker idle while
	// selection is blocked, then release it only after its queue deadline.
	state.mu.@lock()
	state.worker_backend.managed_workers[0].inflight_requests = 0
	time.sleep(300 * time.millisecond)
	state.mu.unlock()
	assert retry_queue_result(result) == 'worker queue timeout'
	assert state.worker_backend.queue_waiting_requests == 0
	assert state.worker_backend.managed_workers[0].inflight_requests == 0
	assert state.worker_backend.managed_workers[0].served_requests == 0
	assert state.stat_queue_timeouts_total == 1
	assert state.lease_idle_socket() or { panic('late selection retained its lease') } == 'queue-owned.sock'
	assert state.request_released('queue-owned.sock')
}

fn test_queue_configuration_error_releases_waiter_without_masking_as_timeout() {
	mut state := retry_queue_busy(1000, 10)
	result := chan string{cap: 1}
	spawn retry_queue_select(mut state, result)
	retry_queue_wait_entered(mut state, result)
	state.mu.@lock()
	state.worker_backend.sockets = []string{}
	state.mu.unlock()
	assert retry_queue_result(result) == 'worker not configured for kind: test'
	assert state.worker_backend.queue_waiting_requests == 0
	assert state.stat_queue_waits_total == 1
	assert state.stat_queue_timeouts_total == 0
	assert state.worker_backend.managed_workers[0].inflight_requests == 1
	assert state.request_released('queue-owned.sock')
}

fn test_failed_connection_releases_once_before_terminal_selection_error() {
	mut probe := &RetryQueueProbe{}
	long_path := '/' + 'x'.repeat(250)
	ctx := ConnectorContext{
		connect_fn:       unix.connect_stream
		select_socket_fn: fn [mut probe, long_path] () !string {
			probe.selects++
			if probe.selects == 1 { return long_path }
			return error('worker queue full')
		}
		release_fn:       fn [mut probe, long_path] (path string) {
			assert path == long_path
			probe.releases++
		}
		emit_fn:          fn [mut probe] (kind string, fields map[string]string) {
			assert kind == 'worker.connect.failed'
			assert fields['attempt'] == '1'
			probe.events++
		}
	}
	if _, _ := ConnectorRuntime.connect_selected(ctx) {
		assert false
	} else {
		assert err.msg() == 'worker queue full'
	}
	assert probe.selects == 2
	assert probe.releases == 1
	assert probe.events == 1
}

fn test_transient_selection_failure_can_transfer_one_live_connection() {
	path := os.join_path(os.temp_dir(), 'vhttpd-retry-success-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut probe := &RetryQueueProbe{}
	ctx := ConnectorContext{
		connect_fn:       unix.connect_stream
		select_socket_fn: fn [mut probe, path] () !string {
			probe.selects++
			if probe.selects == 1 { return error('worker unavailable') }
			return path
		}
		release_fn:       fn [mut probe, path] (selected string) {
			assert selected == path
			probe.releases++
		}
		emit_fn:          fn [mut probe] (_ string, _ map[string]string) { probe.events++ }
	}
	selected, mut conn := ConnectorRuntime.connect_selected(ctx) or { panic(err) }
	mut peer := listener.accept() or { panic(err) }
	defer { peer.close() or {} }
	assert selected == path
	assert probe.selects == 2
	assert probe.releases == 0
	assert probe.events == 0
	conn.close() or { panic(err) }
	ctx.release(selected)
	assert probe.releases == 1
}
