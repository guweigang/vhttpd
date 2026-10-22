module main

import api.openai
import config
import net
import os
import rand
import time

fn passthrough_owner_upstream(mode string) (string, chan bool) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	listener.set_accept_timeout(10 * time.second)
	address := listener.addr() or { panic(err) }
	done := chan bool{cap: 1}
	spawn fn [mut listener, mode, done] () {
		defer {
			listener.close() or {}
			done <- true
		}
		mut conn := listener.accept() or { return }
		defer { conn.close() or {} }
		conn.set_read_timeout(3 * time.second)
		mut request := ''
		mut buffer := []u8{len: 4096}
		for !request.contains('\r\n\r\n') {
			n := conn.read(mut buffer) or { return }
			if n == 0 { return }
			request += buffer[..n].bytestr()
		}
		header_end := request.index('\r\n\r\n') or { return }
		mut length := 0
		for line in request[..header_end].split('\r\n') {
			if line.to_lower().starts_with('content-length:') {
				length = line.all_after(':').trim_space().int()
			}
		}
		for request.len < header_end + 4 + length {
			n := conn.read(mut buffer) or { return }
			if n == 0 { return }
			request += buffer[..n].bytestr()
		}
		if mode == 'malformed' {
			conn.write_string('not HTTP\r\n\r\n') or {}
			return
		}
		if mode in ['primary_error', 'backup_error'] {
			status := if mode == 'primary_error' {
				'503 Service Unavailable'
			} else {
				'429 Too Many Requests'
			}
			body := '{"error":{"code":"${mode}","message":"${mode}"}}'
			conn.write_string('HTTP/1.1 ${status}\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\nConnection: close\r\n\r\n${body}') or {}
			return
		}
		body := 'data: {"content":"backup"}\n\n' + if mode == 'eof' {
			''
		} else {
			'data: [DONE]\n\n'
		}
		if mode == 'done_chunked' {
			conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n${body.len:x}\r\n${body}\r\n0\r\n\r\n') or {}
		} else {
			conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: ${body.len}\r\nConnection: close\r\n\r\n${body}') or {}
		}
	}()
	return 'http://${address}', done
}

fn passthrough_owner_output() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	peer.set_read_timeout(100 * time.millisecond)
	return listener.accept() or { panic(err) }, peer
}

fn passthrough_owner_read(mut peer net.TcpConn) string {
	mut body := ''
	mut buffer := []u8{len: 4096}
	for {
		n := peer.read(mut buffer) or { break }
		if n == 0 { break }
		body += buffer[..n].bytestr()
	}
	return body
}

fn test_passthrough_fetch_normal_completion_is_success_for_plain_and_chunked() {
	for mode in ['done_plain', 'done_chunked'] {
		url, finished := passthrough_owner_upstream(mode)
		mut server, mut peer := passthrough_owner_output()
		defer {
			server.close() or {}
			peer.close() or {}
		}
		mut ctx := Context{}
		mut state := &OpenAIStreamProxyState{ conn: server, method: 'POST', status_code: 200, content_type: 'text/event-stream' }
		failure := state.fetch(mut ctx, openai.OpenAIResolvedPlan{ backend: config.OpenAIBackendConfig{ base_url: url }, method: 'POST', path: '/stream' }, 'POST', 'owner')
		_ := <-finished
		assert failure == '', failure
		assert state.done
		assert state.final_written
	}
}

fn passthrough_owner_fallback(mode string) string {
	primary_url, primary_finished := passthrough_owner_upstream('primary_error')
	backup_url, backup_finished := passthrough_owner_upstream(mode)
	dir := os.join_path(os.temp_dir(), 'vhttpd-passthrough-owner-${rand.uuid_v4()}')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	entry := os.join_path(dir, 'planner.mjs')
	os.write_file(entry, 'export function openai(req) { return {backend:"backup",method:"POST",path:"/stream",stream_mode:"passthrough"}; }') or { panic(err) }
	mut app := &App{}
	app.protocols.openai.plugin = 'planner'
	app.protocols.openai.backends = {
		'backup': config.OpenAIBackendConfig{ base_url: backup_url }
	}
	app.protocols.plugins.publish({
		'planner': config.PluginConfig{ kind: 'vjsx', app_entry: entry, module_root: dir, build_root: os.join_path(dir, 'build'), runtime_profile: 'node', thread_count: 1 }
	})
	defer { app.close_all_plugins() }
	mut server, mut peer := passthrough_owner_output()
	defer {
		server.close() or {}
		peer.close() or {}
	}
	mut ctx := Context{}
	ctx.conn = server
	plan := openai.OpenAIResolvedPlan{ backend_name: 'primary', backend: config.OpenAIBackendConfig{ base_url: primary_url }, method: 'POST', path: '/stream', body: '{"stream":true}', model: 'test' }
	OpenAIProxyRuntime.stream(mut app, mut ctx, plan, 'POST', '/chat', 'owner', 'trace', 0)
	_ := <-primary_finished
	_ := <-backup_finished
	return passthrough_owner_read(mut peer)
}

fn test_passthrough_fallback_done_emits_only_one_http_response() {
	for mode in ['done_plain', 'done_chunked'] {
		body := passthrough_owner_fallback(mode)
		assert body.count('HTTP/1.1') == 1, body
		assert body.contains('backup')
		assert body.count('data: [DONE]') == 1
		assert !body.contains('primary_error')
		assert body.ends_with('0\r\n\r\n'), body
	}
}

fn test_passthrough_fallback_fetch_failure_before_headers_is_502() {
	body := passthrough_owner_fallback('malformed')
	assert body.starts_with('HTTP/1.1 502'), body
	assert body.count('HTTP/1.1') == 1
	assert body.contains('upstream_fetch_failed')
	assert !body.contains('primary_error')
}

fn test_passthrough_fallback_http_error_keeps_backup_status() {
	body := passthrough_owner_fallback('backup_error')
	assert body.starts_with('HTTP/1.1 429'), body
	assert body.count('HTTP/1.1') == 1
	assert body.contains('backup_error')
	assert !body.contains('primary_error')
}

fn test_passthrough_fallback_natural_eof_keeps_single_response() {
	body := passthrough_owner_fallback('eof')
	assert body.starts_with('HTTP/1.1 200'), body
	assert body.count('HTTP/1.1') == 1
	assert body.contains('backup')
	assert !body.contains('primary_error')
	assert body.ends_with('0\r\n\r\n')
}
