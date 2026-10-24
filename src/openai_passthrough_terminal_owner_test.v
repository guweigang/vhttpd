module main

import api.openai
import config
import net.http
import net
import time

fn passthrough_terminal_output(parts []string) (bool, bool, string) {
	mut server, mut peer := passthrough_terminal_pair()
	defer {
		server.close() or {}
		peer.close() or {}
	}
	mut state := &OpenAIStreamProxyState{
		conn:          server
		method:        'POST'
		status_code:   200
		content_type:  'text/event-stream'
		chunk_decoder: openai.ChunkDecodeState{ mode: 'plain' }
	}
	request := &http.Request{ user_ptr: state }
	for part in parts {
		openai_progress_body_cb(request, part.bytes(), 0, 0, 200) or {
			assert err.msg() == openai_stream_done_fetch_error
			break
		}
	}
	return state.done, state.final_written, passthrough_terminal_read(mut peer)
}

fn test_passthrough_terminal_marker_in_content_comment_or_other_field_keeps_stream_alive() {
	for prefix in ['data: {"content":"data: [DONE]"}\n\n', ': data: [DONE]\n\n', 'other: data: [DONE]\n\n',
		'data: [DONE]suffix\n\n', 'data: first\ndata: [DONE]\n\n'] {
		done, _, wire := passthrough_terminal_output([prefix, 'data: later\n\n', 'data: [DONE]\n\n'])
		assert done
		assert wire.contains('later'), wire
	}
}

fn test_passthrough_terminal_waits_for_event_boundary() {
	done, finished, wire := passthrough_terminal_output(['data: [DONE]'])
	assert !done
	assert !finished
	assert wire.contains('[DONE]')
}

fn test_passthrough_terminal_discards_payload_after_complete_event_in_same_callback() {
	for ending in ['\n', '\r\n', '\r'] {
		done, finished, wire := passthrough_terminal_output(['data: first${ending}${ending}data: [DONE]${ending}${ending}data: forbidden${ending}${ending}'])
		assert done
		assert finished
		assert wire.contains('first')
		assert wire.count('[DONE]') == 1
		assert !wire.contains('forbidden'), wire
		assert wire.ends_with('0\r\n\r\n')
	}
}

fn test_passthrough_terminal_handles_optional_space_and_split_crlf() {
	for parts in [['data:[DONE]\n\n'], ['\xef', '\xbb\xbfdata: [DONE]\n\n'],
		['event: done\nid: terminal\ndata: [DONE]\n: comment\n\n'],
		['data: [DO', 'NE]\r', '\n', '\r\nignored'], ['data: [DONE]\n', '\nignored']] {
		done, finished, wire := passthrough_terminal_output(parts)
		assert done
		assert finished
		assert !wire.contains('ignored'), wire
	}
}

fn test_passthrough_terminal_late_callback_cannot_mutate_or_write() {
	mut server, mut peer := passthrough_terminal_pair()
	defer {
		server.close() or {}
		peer.close() or {}
	}
	mut state := &OpenAIStreamProxyState{ conn: server, done: true, status_code: 200 }
	request := &http.Request{ user_ptr: state }
	openai_progress_body_cb(request, 'data: late\n\n'.bytes(), 0, 0, 503) or {
		assert err.msg() == openai_stream_done_fetch_error
	}
	assert state.status_code == 200
	assert !state.headers_written
	assert passthrough_terminal_read(mut peer) == ''
}

fn test_passthrough_terminal_fetch_stops_before_upstream_eof_for_plain_and_chunked() {
	for chunked in [false, true] {
		mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
		listener.set_accept_timeout(3 * time.second)
		address := listener.addr() or { panic(err) }
		release := chan bool{cap: 1}
		finished := chan bool{cap: 1}
		spawn fn [mut listener, chunked, release, finished] () {
			mut timed_out := true
			defer {
				listener.close() or {}
				finished <- timed_out
			}
			mut conn := listener.accept() or { return }
			defer { conn.close() or {} }
			conn.set_read_timeout(3 * time.second)
			mut buffer := []u8{len: 4096}
			mut request := ''
			for !request.contains('\r\n\r\n') {
				n := conn.read(mut buffer) or { return }
				if n == 0 { return }
				request += buffer[..n].bytestr()
			}
			body := 'data: {"content":"data: [DONE]"}\n\ndata: later\n\ndata:[DONE]\n\ndata: forbidden\n\n'
			transfer := if chunked { 'Transfer-Encoding: chunked\r\n' } else { '' }
			payload := if chunked { '${body.len:x}\r\n${body}\r\n' } else { body }
			conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n${transfer}Connection: close\r\n\r\n${payload}') or { return }
			// Keep both HTTP bodies open: completion must release fetch, not wait for EOF.
			select {
				_ := <-release {
					timed_out = false
				}
				3 * time.second {
				}
			}
		}()
		mut server, mut peer := passthrough_terminal_pair()
		defer {
			server.close() or {}
			peer.close() or {}
		}
		mut state := &OpenAIStreamProxyState{ conn: server, method: 'GET', status_code: 200, content_type: 'text/event-stream' }
		mut ctx := Context{}
		failure := state.fetch(mut ctx, openai.OpenAIResolvedPlan{ backend: config.OpenAIBackendConfig{ base_url: 'http://${address}' }, method: 'GET', path: '/stream' }, 'GET', 'terminal-owner')
		release <- true
		timed_out := <-finished
		assert !timed_out
		assert failure == '', failure
		assert state.done
		assert state.final_written
		wire := passthrough_terminal_read(mut peer)
		assert wire.contains('later'), wire
		assert !wire.contains('forbidden'), wire
		assert wire.ends_with('0\r\n\r\n')
	}
}

fn test_passthrough_terminal_fallback_resets_partial_event() {
	mut state := OpenAIStreamProxyState{}
	assert state.terminal_prefix('data: old\n') == 10
	state.reset_for_plan(openai.OpenAIResolvedPlan{})
	assert state.terminal_prefix('data:[DONE]\n\n') == 13
	assert state.done
}

fn passthrough_terminal_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	peer.set_read_timeout(100 * time.millisecond)
	return listener.accept() or { panic(err) }, peer
}

fn passthrough_terminal_read(mut peer net.TcpConn) string {
	mut body := ''
	mut buffer := []u8{len: 4096}
	for {
		n := peer.read(mut buffer) or { break }
		if n == 0 { break }
		body += buffer[..n].bytestr()
	}
	return body
}
