module main

import codex
import command
import executor as execmod
import feishu
import upstream.transport

fn test_feishu_stream_cleanup_does_not_follow_links_into_other_streams() {
	mut state := feishu.FeishuState{
		buffers: {
			'root':   feishu.StreamBuffer{ message_id: 'root', stream_id: 'old', next_message_id: 'new' }
			'orphan': feishu.StreamBuffer{ message_id: 'orphan', stream_id: 'old', next_message_id: 'missing' }
			'new':    feishu.StreamBuffer{ message_id: 'new', stream_id: 'new', content: 'keep' }
		}
	}
	assert state.clear_stream_buffers('old') == 2
	assert state.buffers.len == 1
	assert state.buffers['new'].content == 'keep'
	assert state.clear_stream_buffers('old') == 0
	assert state.clear_stream_buffers('') == 0
}

fn test_feishu_chain_release_captures_owner_and_stops_at_other_stream_boundary() {
	mut state := feishu.FeishuState{
		buffers: {
			'root':  feishu.StreamBuffer{ message_id: 'root', stream_id: 'old', next_message_id: 'child' }
			'child': feishu.StreamBuffer{ message_id: 'child', stream_id: 'old', next_message_id: 'new' }
			'new':   feishu.StreamBuffer{ message_id: 'new', stream_id: 'new', content: 'keep' }
		}
	}
	released := state.release_buffer_chain('root', 'old') or { panic('missing release') }
	assert released.stream_id == 'old'
	assert released.cleared == 2
	assert state.buffers.len == 1
	assert state.buffers['new'].content == 'keep'
	assert state.release_buffer_chain('root', 'old') == none
	assert state.release_buffer_chain('', 'old') == none
}

fn test_feishu_chain_release_rejects_stale_expected_stream_after_rebind() {
	mut state := feishu.FeishuState{}
	state.register_stream_buffer('message', 'old', 'main', '', '', 'old text')
	// A stale command carries old correlation after the same message is rebound.
	state.register_stream_buffer('message', 'new', 'main', '', '', 'new text')
	assert state.release_buffer_chain('message', 'old') == none
	assert state.buffers['message'].stream_id == 'new'
	assert state.buffers['message'].content == 'new text'
	released := state.release_buffer_chain('message', 'new') or { panic('missing release') }
	assert released.stream_id == 'new'
	assert released.cleared == 1
}

fn test_feishu_chain_release_handles_cycles_missing_links_and_unbound_buffers() {
	mut state := feishu.FeishuState{
		buffers: {
			'cycle-a':       feishu.StreamBuffer{ message_id: 'cycle-a', stream_id: 'cycle', next_message_id: 'cycle-b' }
			'cycle-b':       feishu.StreamBuffer{ message_id: 'cycle-b', stream_id: 'cycle', next_message_id: 'cycle-a' }
			'unbound':       feishu.StreamBuffer{ message_id: 'unbound', next_message_id: 'unbound-child' }
			'unbound-child': feishu.StreamBuffer{ message_id: 'unbound-child', next_message_id: 'bound' }
			'bound':         feishu.StreamBuffer{ message_id: 'bound', stream_id: 'bound', next_message_id: 'missing' }
		}
	}
	assert state.clear_buffer_chain('cycle-a') == 2
	assert state.clear_buffer_chain('unbound') == 2
	assert state.buffers.len == 1
	assert state.clear_buffer_chain('bound') == 1
	assert state.clear_buffer_chain('missing') == 0
	assert state.clear_buffer_chain('') == 0
}

fn test_feishu_session_clear_preserves_rebound_buffer_and_new_codex_targets() {
	mut app := &App{}
	app.providers.feishu.register_stream_buffer('message', 'new', 'main', '', '', 'keep')
	for stream in ['old', 'new'] {
		app.codex_add_stream_target('main', stream, codex.CodexTarget{ platform: 'feishu', message_id: 'message' })
	}
	mut handler := FeishuCommandHandler.new(mut app)
	stale := transport.WorkerWebSocketUpstreamCommand{ type_: 'session.clear', provider: 'feishu', stream_id: 'old', target: 'message', target_type: 'message_id' }
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(stale, command.NormalizedCommand.from_worker_command(stale), mut activity)
	assert handled && err == 'feishu_stream_command_retired'
	assert app.providers.feishu.buffers['message'].content == 'keep'
	assert app.providers.codex.snapshot('main').stream_map['new'].len == 1
	assert app.providers.codex.snapshot('main').stream_map['old'].len == 1
	// Target-only clear uses the stream captured during deletion for target cleanup.
	current := transport.WorkerWebSocketUpstreamCommand{
		type_:       'session.clear'
		provider:    'feishu'
		target:      'message'
		target_type: 'message_id'
		metadata:    {
			'stream_generation': (app.providers.feishu.buffer_snapshot('message') or { panic('missing') }).generation
		}
	}
	current_handled, current_err := handler.execute(current, command.NormalizedCommand.from_worker_command(current), mut activity)
	assert current_handled && current_err == ''
	assert app.providers.feishu.buffers.len == 0
	assert app.providers.codex.snapshot('main').stream_map['new'].len == 0
	assert app.providers.codex.snapshot('main').stream_map['old'].len == 1
}

fn test_feishu_concurrent_stream_cleanup_preserves_foreign_successors() {
	mut state := &feishu.FeishuState{}
	mut workers := []thread{}
	for worker in 0 .. 8 {
		workers << spawn fn [mut state, worker] () {
			for index in 0 .. 64 {
				key := '${worker}-${index}'
				state.mu.@lock()
				state.buffers['new-${key}'] = feishu.StreamBuffer{ message_id: 'new-${key}', stream_id: 'new', content: key }
				state.buffers['old-${key}'] = feishu.StreamBuffer{ message_id: 'old-${key}', stream_id: 'old', next_message_id: 'new-${key}' }
				state.mu.unlock()
				state.clear_stream_buffers('old')
			}
		}()
	}
	workers.wait()
	state.clear_stream_buffers('old')
	assert state.buffers.len == 512
	for _, buf in state.buffers {
		assert buf.stream_id == 'new'
	}
}
