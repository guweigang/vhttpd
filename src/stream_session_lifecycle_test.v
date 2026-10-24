module main

import executor
import io
import net
import net.unix
import os
import time
import upstream.transport
import veb
import json2 as json

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int

struct StreamHttpPair {
	server &net.TcpConn @[required]
	peer   &net.TcpConn @[required]
}

fn stream_http_pair() StreamHttpPair {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return StreamHttpPair{ server: listener.accept() or { panic(err) }, peer: peer }
}

fn stream_http_body(mut peer net.TcpConn) string {
	mut result := ''
	mut bytes := []u8{len: 4096}
	for {
		n := peer.read(mut bytes) or {
			assert err is io.Eof, 'stream did not close: ${err}'
			break
		}
		if n == 0 { break }
		result += bytes[..n].bytestr()
	}
	return result
}

@[heap]
struct StreamSessionProbe {
mut:
	open_response  transport.StreamDispatchResponse
	next_response  transport.StreamDispatchResponse
	next_error     bool
	close_error    bool
	interrupt_next bool
	fd             int
	next_calls     int
	closes         []transport.StreamDispatchRequest
	errors         []string
}

fn stream_session_context(mut probe StreamSessionProbe) StreamRuntimeContext {
	return StreamRuntimeContext{
		render_open_failure_fn: fn (mut _ Context, _ HttpIngressRequest, _ executor.KernelStreamDispatchFailure) veb.Result {
			panic('unexpected open failure')
		}
		emit_fn:                fn [mut probe] (kind string, fields map[string]string) {
			if kind == 'http.stream.error' { probe.errors << fields['error_class'] }
		}
		dispatch_open_fn:       fn [mut probe] (_ string, _ string, _ string, _ string, _ string, _ string, _ map[string]string, _ map[string]string) !transport.StreamDispatchResponse {
			return probe.open_response
		}
		dispatch_next_fn:       fn [mut probe] (_ string, _ string, _ string, _ string, _ string, _ map[string]string, _ map[string]string, _ map[string]string) !transport.StreamDispatchResponse {
			probe.next_calls++
			assert probe.next_calls == 1
			if probe.interrupt_next {
				assert net.shutdown(probe.fd, how: .write) == 0
			}
			if probe.next_error { return error('injected read failure') }
			return probe.next_response
		}
		dispatch_close_fn:      fn [mut probe] (id string, trace string, state map[string]string, reason string) !transport.StreamDispatchResponse {
			probe.closes << transport.StreamDispatchRequest{ request_id: id, trace_id: trace, state: state.clone(), reason: reason }
			if probe.close_error { return error('injected close failure') }
			return transport.StreamDispatchResponse{}
		}
	}
}

fn run_stream_session(mut probe StreamSessionProbe, pair StreamHttpPair, method string) {
	probe.fd = pair.server.sock.handle
	mut ctx := Context{}
	ctx.conn = pair.server
	rt := stream_session_context(mut probe)
	if _result := HttpStreamRuntime.dispatch(rt, mut ctx, method, '/events', 'request', 'trace', 'peer') {
		assert probe.closes.len == 1
		assert probe.closes[0].request_id == 'request'
		assert probe.closes[0].trace_id == 'trace'
	} else {
		panic('handled stream fell back')
	}
	assert C.fcntl(probe.fd, C.F_GETFD, 0) == -1, 'taken-over HTTP descriptor leaked'
}

fn test_dispatch_header_write_failure_closes_socket_and_session_even_if_close_fails() {
	for stream_type in ['sse', 'text'] {
		pair := stream_http_pair()
		mut peer := pair.peer
		defer { peer.close() or {} }
		assert net.shutdown(pair.server.sock.handle, how: .write) == 0
		mut probe := &StreamSessionProbe{
			open_response: transport.StreamDispatchResponse{
				handled:     true
				stream_type: stream_type
				state:       {
					'cursor': 'open'
				}
			}
			close_error:   true
		}
		run_stream_session(mut probe, pair, 'GET')
		assert probe.next_calls == 0
		assert probe.closes[0].reason == 'client_write_error'
		assert probe.closes[0].state == {
			'cursor': 'open'
		}
	}
}

fn test_dispatch_chunk_write_failure_closes_once_with_latest_state() {
	for stream_type in ['sse', 'text'] {
		pair := stream_http_pair()
		mut peer := pair.peer
		defer { peer.close() or {} }
		mut probe := &StreamSessionProbe{
			open_response:  transport.StreamDispatchResponse{
				handled:     true
				stream_type: stream_type
				state:       {
					'cursor': 'open'
				}
			}
			next_response:  transport.StreamDispatchResponse{
				done:   true
				state:  {
					'cursor': 'next'
				}
				chunks: [transport.StreamDispatchChunk{ data: 'body' }]
			}
			interrupt_next: true
		}
		run_stream_session(mut probe, pair, 'GET')
		assert probe.closes[0].reason == 'client_write_error'
		assert probe.closes[0].state == {
			'cursor': 'next'
		}
	}
}

fn test_dispatch_read_and_worker_errors_preserve_failure_reason_and_owned_state() {
	for failure in ['transport_error', 'worker_runtime_error'] {
		pair := stream_http_pair()
		mut peer := pair.peer
		defer { peer.close() or {} }
		mut probe := &StreamSessionProbe{
			open_response: transport.StreamDispatchResponse{
				handled: true
				state:   {
					'cursor': 'open'
				}
			}
			next_response: transport.StreamDispatchResponse{ event: 'error', error: 'worker failed', error_class: failure }
			next_error:    failure == 'transport_error'
		}
		run_stream_session(mut probe, pair, 'GET')
		assert probe.closes[0].reason == failure
		assert probe.closes[0].state == {
			'cursor': 'open'
		}
		assert probe.errors == [failure]
	}
}

fn test_dispatch_success_and_head_finish_once_and_release_http_descriptor() {
	for method in ['GET', 'HEAD'] {
		pair := stream_http_pair()
		mut peer := pair.peer
		defer { peer.close() or {} }
		mut probe := &StreamSessionProbe{
			open_response: transport.StreamDispatchResponse{
				handled:     true
				stream_type: 'text'
				state:       {
					'cursor': 'open'
				}
				chunks:      [transport.StreamDispatchChunk{ data: 'first' }]
			}
			next_response: transport.StreamDispatchResponse{
				done:   true
				state:  {
					'cursor': 'last'
				}
				chunks: [transport.StreamDispatchChunk{ data: 'last' }]
			}
		}
		run_stream_session(mut probe, pair, method)
		body := stream_http_body(mut peer)
		assert body.starts_with('HTTP/1.1 200 OK')
		assert body.ends_with('0\r\n\r\n') == (method == 'GET')
		assert body.contains('first') == (method == 'GET')
		assert body.contains('last') == (method == 'GET')
		assert probe.closes[0].reason == 'completed'
		assert probe.next_calls == if method == 'GET' { 1 } else { 0 }
		assert probe.closes[0].state == {
			'cursor': if method == 'GET' { 'last' } else { 'open' }
		}
	}
}

fn test_dispatch_final_chunk_failure_is_not_reported_as_completed() {
	pair := stream_http_pair()
	mut peer := pair.peer
	defer { peer.close() or {} }
	mut probe := &StreamSessionProbe{
		open_response:  transport.StreamDispatchResponse{ handled: true, stream_type: 'text' }
		next_response:  transport.StreamDispatchResponse{ done: true }
		interrupt_next: true
	}
	run_stream_session(mut probe, pair, 'GET')
	assert probe.closes[0].reason == 'client_write_error'
}

fn test_direct_stream_header_failure_closes_http_but_leaves_worker_with_caller() {
	for stream_type in ['sse', 'passthrough'] {
		root := os.join_path(os.temp_dir(), 'vhttpd-stream-owner-${os.getpid()}-${time.now().unix_micro()}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		mut listener := unix.listen_stream(root + '/worker.sock') or { panic(err) }
		defer { listener.close() or {} }
		mut writer := unix.connect_stream(root + '/worker.sock') or { panic(err) }
		defer { writer.close() or {} }
		mut worker_conn := listener.accept() or { panic(err) }
		defer { worker_conn.close() or {} }
		pair := stream_http_pair()
		mut peer := pair.peer
		defer { peer.close() or {} }
		fd := pair.server.sock.handle
		assert net.shutdown(fd, how: .write) == 0
		mut ctx := Context{}
		ctx.conn = pair.server
		mut probe := &StreamSessionProbe{}
		rt := stream_session_context(mut probe)
		start := transport.WorkerStreamFrame{ stream_type: stream_type }
		if stream_type == 'sse' {
			HttpStreamRuntime.direct_sse(rt, mut ctx, mut worker_conn, start, 'GET', '/events', 'req', 'trace', 0)
		} else {
			HttpStreamRuntime.direct_passthrough(rt, mut ctx, mut worker_conn, start, 'GET', '/events', 'req', 'trace', 0)
		}
		assert C.fcntl(fd, C.F_GETFD, 0) == -1
		assert C.fcntl(worker_conn.sock.handle, C.F_GETFD, 0) >= 0
		// A live worker descriptor is still usable and must be closed by the outer owner.
		transport.WorkerFrameCodec.write(mut writer, json.encode(transport.WorkerStreamFrame{ mode: 'stream', event: 'end' })) or { panic(err) }
		assert transport.WorkerFrameCodec.read(mut worker_conn) or { panic(err) } != ''
		assert probe.closes.len == 0
	}
}

fn test_dispatch_head_closes_open_state_without_reading_stream_or_writing_body() {
	for stream_type in ['sse', 'text'] {
		for done in [false, true] {
			for close_error in [false, true] {
				pair := stream_http_pair()
				mut peer := pair.peer
				defer { peer.close() or {} }
				mut probe := &StreamSessionProbe{
					open_response: transport.StreamDispatchResponse{
						handled:     true
						done:        done
						stream_type: stream_type
						state:       {
							'cursor': 'open'
						}
						chunks:      [transport.StreamDispatchChunk{ data: 'must not be written' }]
					}
					// Reading an endless stream would fail this fixture; HEAD must not call next.
					next_error:    true
					close_error:   close_error
				}
				run_stream_session(mut probe, pair, 'hEaD')
				response := stream_http_body(mut peer)
				assert response.starts_with('HTTP/1.1 200 OK')
				assert response.all_after('\r\n\r\n') == ''
				assert probe.next_calls == 0
				assert probe.closes[0].state == {
					'cursor': 'open'
				}
				assert probe.closes[0].reason == 'completed'
				assert probe.errors.len == 0
			}
		}
	}
}

fn test_direct_head_does_not_read_worker_frames_and_leaves_connection_with_caller() {
	for stream_type in ['sse', 'passthrough'] {
		root := os.join_path(os.temp_dir(), 'vhttpd-head-owner-${os.getpid()}-${time.now().unix_micro()}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		mut listener := unix.listen_stream(root + '/worker.sock') or { panic(err) }
		defer { listener.close() or {} }
		mut writer := unix.connect_stream(root + '/worker.sock') or { panic(err) }
		defer { writer.close() or {} }
		mut worker_conn := listener.accept() or { panic(err) }
		defer { worker_conn.close() or {} }
		worker_conn.set_read_timeout(time.second)
		first := json.encode(transport.WorkerStreamFrame{ mode: 'stream', event: 'chunk', data: 'unconsumed' })
		transport.WorkerFrameCodec.write(mut writer, first) or { panic(err) }
		transport.WorkerFrameCodec.write(mut writer, json.encode(transport.WorkerStreamFrame{ mode: 'stream', event: 'end' })) or { panic(err) }
		pair := stream_http_pair()
		mut peer := pair.peer
		defer { peer.close() or {} }
		fd := pair.server.sock.handle
		mut ctx := Context{}
		ctx.conn = pair.server
		mut probe := &StreamSessionProbe{}
		rt := stream_session_context(mut probe)
		start := transport.WorkerStreamFrame{ stream_type: stream_type }
		if stream_type == 'sse' {
			HttpStreamRuntime.direct_sse(rt, mut ctx, mut worker_conn, start, 'HEAD', '/events', 'req', 'trace', 0)
		} else {
			HttpStreamRuntime.direct_passthrough(rt, mut ctx, mut worker_conn, start, 'HEAD', '/events', 'req', 'trace', 0)
		}
		response := stream_http_body(mut peer)
		assert response.starts_with('HTTP/1.1 200 OK')
		assert response.all_after('\r\n\r\n') == ''
		assert C.fcntl(fd, C.F_GETFD, 0) == -1
		assert C.fcntl(worker_conn.sock.handle, C.F_GETFD, 0) >= 0
		assert (transport.WorkerFrameCodec.read(mut worker_conn) or { panic(err) }) == first
		assert probe.closes.len == 0
	}
}

@[heap]
struct HeadStreamLeaseProbe {
mut:
	finishes int
}

fn test_http_head_stream_releases_worker_before_finishing_lease_once() {
	for stream_type in ['sse', 'text'] {
		root := os.join_path(os.temp_dir(), 'vhttpd-head-lease-${os.getpid()}-${time.now().unix_micro()}')
		os.mkdir_all(root) or { panic(err) }
		defer { os.rmdir_all(root) or {} }
		mut listener := unix.listen_stream(root + '/worker.sock') or { panic(err) }
		defer { listener.close() or {} }
		mut writer := unix.connect_stream(root + '/worker.sock') or { panic(err) }
		defer { writer.close() or {} }
		worker_conn := listener.accept() or { panic(err) }
		worker_fd := worker_conn.sock.handle
		mut probe := &HeadStreamLeaseProbe{}
		mut lease := &executor.WorkerRequestLease{
			socket_path: root + '/worker.sock'
			finish_fn:   fn [mut probe, worker_fd] (_ string) {
				assert C.fcntl(worker_fd, C.F_GETFD, 0) == -1
				probe.finishes++
			}
		}
		lease.retain_connection(worker_conn)
		mut outcome := executor.HttpLogicDispatchOutcome{
			kind:         .stream
			stream_start: transport.WorkerStreamFrame{ stream_type: stream_type }
			lease:        lease
		}
		pair := stream_http_pair()
		mut peer := pair.peer
		defer { peer.close() or {} }
		mut ctx := Context{}
		ctx.conn = pair.server
		mut app := &App{}
		HttpResponseRuntime.stream(mut app, mut ctx, HttpIngressRequest{ method: 'HEAD', path: '/events' }, mut outcome)
		assert stream_http_body(mut peer).all_after('\r\n\r\n') == ''
		assert probe.finishes == 1
		outcome.close_live_conn()
		outcome.finish_worker()
		assert probe.finishes == 1
	}
}
