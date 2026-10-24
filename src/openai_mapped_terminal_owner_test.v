module main

import api.openai
import net
import net.http
import time

fn mapped_owner_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	peer.set_read_timeout(100 * time.millisecond)
	return listener.accept() or { panic(err) }, peer
}

fn mapped_owner_read(mut peer net.TcpConn) string {
	mut result := ''
	mut buffer := []u8{len: 4096}
	for {
		n := peer.read(mut buffer) or { break }
		if n == 0 { break }
		result += buffer[..n].bytestr()
	}
	return result
}

fn mapped_owner_chunk(mut state OpenAIMappedStreamProxyState, chunk string, status int) string {
	request := http.Request{ user_ptr: &state }
	openai_mapped_progress_body_cb(&request, chunk.bytes(), 0, 0, status) or { return err.msg() }
	return ''
}

fn test_mapped_terminal_row_discards_remaining_rows_and_partial_tail() {
	mut server, mut peer := mapped_owner_pair()
	defer { server.close() or {} }
	defer { peer.close() or {} }
	mut state := &OpenAIMappedStreamProxyState{ conn: server, method: 'POST', status_code: 200 }
	failure := mapped_owner_chunk(mut state, '{"response":"first"}\n{"response":"final","done":true}\n{"response":"late","done":true}\npartial', 200)
	assert failure == openai_stream_done_fetch_error
	assert state.line_buffer == ''
	body := mapped_owner_read(mut peer)
	assert body.contains('first')
	assert body.contains('final')
	assert !body.contains('late')
	assert body.count('data: [DONE]') == 1
	assert body.ends_with('0\r\n\r\n')
}

fn test_mapped_direct_tail_after_completion_does_not_write_after_final_chunk() {
	mut server, mut peer := mapped_owner_pair()
	defer { server.close() or {} }
	defer { peer.close() or {} }
	mut state := &OpenAIMappedStreamProxyState{ conn: server, method: 'POST', status_code: 200 }
	state.write_mapped_line('{"response":"final","done":true}') or { panic(err) }
	state.write_mapped_line('{"response":"late-tail"}') or { panic(err) }
	body := mapped_owner_read(mut peer)
	assert !body.contains('late-tail')
	assert body.ends_with('0\r\n\r\n')
}

fn test_mapped_late_callback_cannot_mutate_terminal_status_or_error_body() {
	mut server, mut peer := mapped_owner_pair()
	defer { server.close() or {} }
	defer { peer.close() or {} }
	mut state := &OpenAIMappedStreamProxyState{ conn: server, method: 'POST', status_code: 200 }
	state.write_mapped_line('{"done":true}') or { panic(err) }
	assert mapped_owner_chunk(mut state, 'late-error', 503) == openai_stream_done_fetch_error
	assert state.status_code == 200
	assert state.error_body == ''
}

fn test_mapped_fragmented_completion_owns_unterminated_buffer() {
	mut server, mut peer := mapped_owner_pair()
	defer { server.close() or {} }
	defer { peer.close() or {} }
	mut state := &OpenAIMappedStreamProxyState{ conn: server, method: 'POST', status_code: 200 }
	assert mapped_owner_chunk(mut state, '{"response":"final",', 200) == ''
	assert mapped_owner_chunk(mut state, '"done":true}\n{"response":"tail"}', 200) == openai_stream_done_fetch_error
	assert state.line_buffer == ''
	assert mapped_owner_chunk(mut state, '{"response":"late"}\n', 200) == openai_stream_done_fetch_error
	body := mapped_owner_read(mut peer)
	assert !body.contains('tail')
	assert !body.contains('late')
}

@[heap]
struct MappedOwnerMapper {
mut:
	calls int
}

fn (mut host MappedOwnerMapper) openai_plugin_map_frame(_ openai.OpenAIResolvedPlan, _ string, _ string, _ string) !openai.OpenAIFrameMapping {
	host.calls++
	return openai.OpenAIFrameMapping{ handled: true, done: true, error: 'mapper_failed' }
}

fn test_mapped_error_does_not_invoke_mapper_again_or_emit_repeated_errors() {
	mut server, mut peer := mapped_owner_pair()
	defer { server.close() or {} }
	defer { peer.close() or {} }
	mut host := &MappedOwnerMapper{}
	mut state := &OpenAIMappedStreamProxyState{ conn: server, method: 'POST', status_code: 200, mapper: 'plugin', mapper_host: OpenAIFrameMapperHost(host) }
	assert mapped_owner_chunk(mut state, '{}\n{}\n', 200) == openai_stream_done_fetch_error
	assert host.calls == 1
	assert state.line_buffer == ''
	body := mapped_owner_read(mut peer)
	assert body.count('mapper_failed') == 1
	assert body.ends_with('0\r\n\r\n')
}

fn test_mapped_fallback_owns_new_chunk_decoder() {
	for mode in ['plain', 'chunked', 'completed'] {
		mut server, mut peer := mapped_owner_pair()
		defer { server.close() or {} }
		defer { peer.close() or {} }
		mut state := &OpenAIMappedStreamProxyState{ conn: server, method: 'POST', status_code: 503 }
		state.chunk_decoder = openai.ChunkDecodeState{
			mode:      if mode == 'plain' {
				'plain'
			} else {
				'chunked'
			}
			buffer:    'old-partial'
			remaining: 99
			done:      mode == 'completed'
		}
		state.reset_for_plan(openai.OpenAIResolvedPlan{ model: 'fallback' })
		assert state.chunk_decoder.mode == 'unknown'
		assert state.chunk_decoder.buffer == ''
		assert !state.chunk_decoder.done
		row := '{"response":"fallback","done":true}\n'
		assert mapped_owner_chunk(mut state, '${row.len:x}\r\n${row}\r\n0\r\n\r\n', 200) == openai_stream_done_fetch_error
		assert mapped_owner_read(mut peer).contains('fallback')
	}
}

fn test_mapped_terminal_write_failure_does_not_reopen_output() {
	mut server, mut peer := mapped_owner_pair()
	defer { server.close() or {} }
	defer { peer.close() or {} }
	assert net.shutdown(server.sock.handle, how: .write) == 0
	mut state := &OpenAIMappedStreamProxyState{ conn: server, method: 'POST', status_code: 200 }
	mut failed := false
	state.write_mapped_line('{"done":true}') or { failed = true }
	assert failed
	assert state.done
	state.write_mapped_line('{"response":"late"}') or { panic('terminal stream attempted another write') }
}
