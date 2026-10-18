module main

import executor
import worker
import upstream.transport
import net.http
import net.unix
import os
import time

fn origin_pool(path string, cgi bool, inflight i64) &worker.WorkerState {
	mut state := &worker.WorkerState{
		worker_backend: worker.WorkerBackendRuntime{
			autostart:       true
			sockets:         [path]
			read_timeout_ms: 1000
			env:             {
				'DOCUMENT_ROOT': 'original-root'
			}
			managed_workers: [transport.ManagedWorker{
				id:                1
				socket_path:       path
				inflight_requests: inflight
				next_retry_ts:     time.now().unix_milli() + 60000
			}]
		}
	}
	if cgi { state.logic_executor = executor.PhpCgiExecutor{} }
	return state
}

fn origin_wait(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			assert false, 'origin fixture timed out'
		}
	}
}

fn origin_peer(mut listener unix.StreamListener, cgi bool, stream bool, entered chan bool, release chan bool, done chan bool) {
	mut peer := listener.accept() or { panic(err) }
	defer {
		peer.close() or {}
		done <- true
	}
	if cgi {
		for {
			header := worker.WorkerBackendFrameCodec.read_exact(mut peer, 8) or { panic(err) }
			length := (int(header[4]) << 8) | int(header[5])
			if length + int(header[6]) > 0 {
				_ := worker.WorkerBackendFrameCodec.read_exact(mut peer, length + int(header[6])) or { panic(err) }
			}
			if header[1] == 5 && length == 0 { break }
		}
	} else {
		_ := worker.WorkerBackendFrameCodec.read(mut peer) or { panic(err) }
	}
	entered <- true
	_ := <-release
	if cgi {
		body := 'Status: 200 OK\r\nContent-Type: text/plain\r\n\r\noriginal'
		out := transport.FastCgiRecord{ @type: 6, content_length: u16(body.len), content: body.bytes() }.encode()
		peer.write(out) or { panic(err) }
		peer.write(transport.FastCgiRecord{ @type: 3, content_length: 8, content: []u8{len: 8} }.encode()) or { panic(err) }
	} else {
		payload := if stream {
			'{"mode":"stream","event":"start","stream_type":"text","status":200}'
		} else {
			'{"status":200,"body":"original"}'
		}
		worker.WorkerBackendFrameCodec.write(mut peer, payload) or { panic(err) }
	}
}

fn origin_http_call(mut app App, done chan string) {
	selection := app.engines.dispatch_selection('')
	mut facade := app.as_facade()
	result := selection.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{
		method: 'GET'
		path:   '/index.php'
		req:    http.Request{}
	}) or {
		done <- err.msg()
		return
	}
	done <- result.response.body
}

fn origin_http_publication(cgi bool) {
	path := os.join_path(os.temp_dir(), 'vhttpd-http-origin-${os.getpid()}-${cgi}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := origin_pool(path, cgi, 0)
	mut next := origin_pool(path, cgi, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	peer_done := chan bool{cap: 1}
	client_done := chan string{cap: 1}
	spawn origin_peer(mut listener, cgi, false, entered, release, peer_done)
	spawn origin_http_call(mut app, client_done)
	origin_wait(entered)
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: next }
	app.mu.unlock()
	release <- true
	mut body := ''
	select {
		value := <-client_done {
			body = value
		}
		3 * time.second {
			assert false, 'HTTP request did not finish'
		}
	}
	origin_wait(peer_done)
	assert body == 'original'
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 1
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
}

fn test_http_completion_keeps_its_origin_after_runtime_publication() {
	origin_http_publication(false)
}

fn test_fastcgi_completion_keeps_its_origin_after_runtime_publication() {
	origin_http_publication(true)
}

fn test_stream_outcome_cleanup_releases_its_original_worker() {
	path := os.join_path(os.temp_dir(), 'vhttpd-stream-origin-${os.getpid()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	mut old := origin_pool(path, false, 0)
	mut next := origin_pool(path, false, 1)
	mut app := &App{ engines: EngineRuntime{ primary: old } }
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	done := chan bool{cap: 1}
	release <- true
	spawn origin_peer(mut listener, false, true, entered, release, done)
	selection := app.engines.dispatch_selection('')
	mut facade := app.as_facade()
	mut outcome := selection.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{}) or { panic(err) }
	origin_wait(entered)
	origin_wait(done)
	assert outcome.kind == .stream
	app.engines = EngineRuntime{ primary: next }
	outcome.close_live_conn()
	assert old.worker_backend.managed_workers[0].inflight_requests == 0
	assert old.worker_backend.managed_workers[0].served_requests == 1
	assert next.worker_backend.managed_workers[0].inflight_requests == 1
}

fn test_named_http_pool_does_not_fall_back_to_same_kind_primary() {
	mut primary := origin_pool('/tmp/' + 'x'.repeat(200), false, 1)
	mut target := origin_pool('/tmp/' + 'y'.repeat(200), false, 0)
	mut app := &App{
		engines: EngineRuntime{
			primary:    primary
			additional: {
				'alternate': target
			}
		}
	}
	selection := app.engines.dispatch_selection('alternate')
	mut facade := app.as_facade()
	if _ := selection.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{}) {
		assert false
	} else {
		assert !err.msg().contains('worker queue full')
	}
	assert primary.worker_backend.managed_workers[0].inflight_requests == 1
	assert target.worker_backend.managed_workers[0].inflight_requests == 0
}
