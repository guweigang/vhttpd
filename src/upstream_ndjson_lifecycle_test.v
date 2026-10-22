module main

import io
import net
import net.http
import os
import time
import upstream
import upstream.transport

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int

@[heap]
struct NdjsonOutputProbe {
mut:
	headers    int
	pieces     []string
	events     []string
	fail_done  bool
	fail_piece bool
}

fn ndjson_probe_state(mut probe NdjsonOutputProbe, mode string) &upstream.ExecState {
	return &upstream.ExecState{
		io:                  upstream.Io{
			write_http_stream_headers_conn: fn [mut probe] (mut _ net.TcpConn, _ int, _ string, _ map[string]string, _ bool) ! {
				probe.headers++
			}
			write_sse_message:              fn [mut probe] (mut _ net.TcpConn, frame transport.WorkerStreamFrame) ! {
				if frame.sse_event == 'done' && probe.fail_done {
					return error('injected_done_write_failure')
				}
				if frame.sse_event != 'done' && probe.fail_piece {
					return error('injected_piece_write_failure')
				}
				probe.events << frame.sse_event
				if frame.sse_event != 'done' { probe.pieces << frame.data }
			}
			write_chunk:                    fn [mut probe] (mut _ net.TcpConn, piece string) ! {
				if probe.fail_piece { return error('injected_piece_write_failure') }
				probe.pieces << piece
			}
		}
		method:              if mode == 'HEAD' { 'HEAD' } else { 'GET' }
		stream_type:         if mode == 'text' { 'text' } else { 'sse' }
		field_path:          'message.content'
		fallback_field_path: 'response'
	}
}

fn test_ndjson_done_owns_terminal_output_and_discards_buffered_late_rows() {
	for mode in ['sse', 'text', 'HEAD'] {
		mut probe := &NdjsonOutputProbe{}
		mut state := ndjson_probe_state(mut probe, mode)
		state.consume_chunk('{"response":"first"}\n{"response":"final","done":true}\n{"response":"late","done":true}\npartial') or { panic(err) }
		state.consume_chunk('{"response":"later"}\n') or { panic(err) }
		state.flush_buffer() or { panic(err) }
		state.write_line('{"response":"direct-late","done":true}') or { panic(err) }
		assert probe.pieces == if mode == 'HEAD' { []string{} } else { ['first', 'final'] }
		assert probe.events.filter(it == 'done').len == if mode == 'sse' { 1 } else { 0 }
		assert state.line_buf == ''
		assert probe.headers == 1
	}
}

fn test_ndjson_fragmented_terminal_row_stops_subsequent_chunks() {
	mut probe := &NdjsonOutputProbe{}
	mut state := ndjson_probe_state(mut probe, 'sse')
	for chunk in ['{"response":"last",', '"done":tr', 'ue}\n{"response":"late"}\n'] {
		state.consume_chunk(chunk) or { panic(err) }
	}
	state.consume_chunk('{"done":true}\n') or { panic(err) }
	assert probe.pieces == ['last']
	assert probe.events == ['message', 'done']
}

fn test_ndjson_fixture_completion_does_not_publish_following_rows() {
	path := os.join_path(os.temp_dir(), 'vhttpd-ndjson-done-${os.getpid()}-${time.now().unix_micro()}.ndjson')
	os.write_file(path, '{"response":"last","done":true}\n{"response":"late"}\n{"done":true}\n') or { panic(err) }
	defer { os.rm(path) or {} }
	mut probe := &NdjsonOutputProbe{}
	mut state := ndjson_probe_state(mut probe, 'sse')
	state.execute_fixture(transport.WorkerUpstreamPlanFrame{ fixture_path: path }) or { panic(err) }
	assert probe.pieces == ['last']
	assert probe.events == ['message', 'done']
}

fn test_ndjson_eof_flush_and_invalid_rows_keep_existing_behavior() {
	mut probe := &NdjsonOutputProbe{}
	mut state := ndjson_probe_state(mut probe, 'sse')
	state.consume_chunk('\nnot json\n{"message":{"content":"first"}}\n{"response":"tail"}') or { panic(err) }
	state.flush_buffer() or { panic(err) }
	assert probe.pieces == ['first', 'tail']
	assert probe.events == ['message', 'message']
	assert state.line_buf == ''
}

fn test_ndjson_terminal_and_content_write_errors_are_not_completion() {
	for fail_done in [true, false] {
		mut probe := &NdjsonOutputProbe{ fail_done: fail_done, fail_piece: !fail_done }
		mut state := ndjson_probe_state(mut probe, 'sse')
		request := http.Request{ user_ptr: state }
		mut error_message := ''
		upstream.progress_body_cb(&request, '{"response":"last","done":true}\n'.bytes(), 0, 0, 200) or { error_message = err.msg() }
		assert error_message == if fail_done {
			'injected_done_write_failure'
		} else {
			'injected_piece_write_failure'
		}
	}
}

// Hold the HTTP body open after a terminal NDJSON row. The test owns release;
// neither success nor failure relies on a timeout to clean up its child task.
struct NdjsonHeldOrigin {
	url     string
	ready   chan bool
	release chan bool
	closed  chan bool
}

fn ndjson_held_origin() NdjsonHeldOrigin {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	address := listener.addr() or { panic(err) }
	fixture := NdjsonHeldOrigin{
		url:     'http://${address}/stream'
		ready:   chan bool{cap: 1}
		release: chan bool{cap: 1}
		closed:  chan bool{cap: 1}
	}
	spawn fn [mut listener, fixture] () {
		defer { listener.close() or {} }
		mut conn := listener.accept() or { panic(err) }
		defer { conn.close() or {} }
		conn.set_read_timeout(time.second)
		mut buffer := []u8{len: 4096}
		mut request := ''
		for !request.contains('\r\n\r\n') {
			n := conn.read(mut buffer) or { panic(err) }
			assert n > 0
			request += buffer[..n].bytestr()
		}
		payload := '{"response":"last","done":true}\n'
		conn.write_string('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/x-ndjson\r\n\r\n${payload.len.hex()}\r\n${payload}\r\n') or { panic(err) }
		fixture.ready <- true
		_ := <-fixture.release
		mut eof := false
		n := conn.read(mut buffer) or {
			eof = err is io.Eof
			-1
		}
		fixture.closed <- (eof || n == 0)
	}()
	return fixture
}

fn ndjson_wait_ready(ch chan bool) {
	select {
		value := <-ch {
			assert value
		}
		3 * time.second {
			panic('NDJSON fixture did not become ready')
		}
	}
}

fn ndjson_finished_while_origin_open(done chan string, fixture NdjsonHeldOrigin) (bool, string, bool) {
	ndjson_wait_ready(fixture.ready)
	mut completed := false
	mut result := ''
	select {
		message := <-done {
			completed = true
			result = message
		}
		300 * time.millisecond {
		}
	}
	fixture.release <- true
	mut peer_closed := false
	select {
		value := <-fixture.closed {
			peer_closed = value
		}
		3 * time.second {
			panic('NDJSON origin cleanup deadline')
		}
	}
	if !completed {
		select {
			message := <-done {
				result = message
			}
			3 * time.second {
				panic('NDJSON execution did not release after origin close')
			}
		}
	}
	return completed, result, peer_closed
}

fn test_ndjson_http_completion_closes_origin_without_waiting_for_http_eof() {
	for mode in ['sse', 'text', 'HEAD'] {
		origin := ndjson_held_origin()
		mut probe := &NdjsonOutputProbe{}
		mut state := ndjson_probe_state(mut probe, mode)
		done := chan string{cap: 1}
		spawn fn [mut state, origin, done] () {
			state.execute_http(transport.WorkerUpstreamPlanFrame{ url: origin.url, method: 'GET' }) or {
				done <- err.msg()
				return
			}
			done <- ''
		}()
		completed, error_message, peer_closed := ndjson_finished_while_origin_open(done, origin)
		assert completed, 'protocol completion retained the HTTP request until EOF'
		assert error_message == ''
		assert peer_closed, 'HTTP reader returned without closing its upstream socket'
		assert probe.pieces == if mode == 'HEAD' { []string{} } else { ['last'] }
	}
}

fn test_ndjson_runtime_completion_releases_registration_and_downstream() {
	origin := ndjson_held_origin()
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	defer { peer.close() or {} }
	peer.set_read_timeout(time.second)
	server := listener.accept() or { panic(err) }
	fd := server.sock.handle
	mut app := &App{}
	rt := app.build_upstream_runtime_context()
	done := chan string{cap: 1}
	plan := transport.WorkerUpstreamPlanFrame{
		url:                origin.url
		method:             'GET'
		transport:          'http'
		codec:              'ndjson'
		mapper:             'ndjson_sse_field'
		output_stream_type: 'sse'
	}
	spawn fn [rt, server, plan, done] () {
		mut ctx := Context{ conn: server }
		UpstreamRuntimeContext.execute_plan(rt, mut ctx, plan, 'GET', '/events', 'ndjson-owner', 'trace', 0)
		done <- ''
	}()
	completed, error_message, peer_closed := ndjson_finished_while_origin_open(done, origin)
	assert completed, 'upstream registration stayed live after the terminal row'
	assert error_message == ''
	assert peer_closed
	assert app.upstreams.active_count() == 0
	plans, errors := app.upstreams.totals()
	assert plans == 1
	assert errors == 0
	assert C.fcntl(fd, C.F_GETFD, 0) == -1
	mut body := ''
	mut buffer := []u8{len: 4096}
	for {
		n := peer.read(mut buffer) or {
			assert err is io.Eof
			break
		}
		if n == 0 { break }
		body += buffer[..n].bytestr()
	}
	assert body.contains('data: last\n')
	assert body.count('event: done\n') == 1
	assert !body.contains('event: error\n')
}

fn test_ndjson_http_write_error_unwinds_reader_without_becoming_success() {
	origin := ndjson_held_origin()
	mut probe := &NdjsonOutputProbe{ fail_done: true }
	mut state := ndjson_probe_state(mut probe, 'sse')
	done := chan string{cap: 1}
	spawn fn [mut state, origin, done] () {
		state.execute_http(transport.WorkerUpstreamPlanFrame{ url: origin.url, method: 'GET' }) or {
			done <- err.msg()
			return
		}
		done <- ''
	}()
	completed, error_message, peer_closed := ndjson_finished_while_origin_open(done, origin)
	assert completed
	assert error_message == 'injected_done_write_failure'
	assert peer_closed
}
