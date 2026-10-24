module main

import command
import executor as execmod
import feishu
import upstream.transport

fn feishu_rollover_state() &feishu.FeishuState {
	mut state := &feishu.FeishuState{}
	state.register_stream_buffer('root', 'stream', 'main', 'chat', 'chat_id', 'finished')
	state.buffers['root'].sealed = true
	return state
}

fn test_feishu_rollover_single_claim_coalesces_later_deltas() {
	mut state := feishu_rollover_state()
	claim := state.append_buffer_patch('root', 'main', 'first') or { panic('missing claim') }
	assert state.append_buffer_patch('root', 'main', ' second') == none
	assert state.append_buffer_patch('root', 'main', ' third') == none
	assert state.commit_buffer_rollover(claim, 'next', 1000)
	assert state.buffers['root'].next_message_id == 'next'
	assert state.buffers['next'].content == 'first second third'
	assert state.buffers['next'].rendered_content == 'first'
	assert state.pending_buffer_snapshots(2000).len == 1
	assert state.append_buffer_patch('root', 'main', ' fourth') == none
	assert state.buffers['next'].content == 'first second third fourth'
	assert !state.commit_buffer_rollover(claim, 'duplicate', 2000)
	assert state.buffers.len == 2
}

fn test_feishu_rollover_rejects_clear_rebind_and_same_id_recreation() {
	for scenario in ['clear', 'rebind', 'recreate'] {
		mut state := feishu_rollover_state()
		claim := state.append_buffer_patch('root', 'main', 'old') or { panic('missing') }
		if scenario == 'clear' {
			state.clear_stream_buffers('stream')
		} else {
			if scenario == 'recreate' { state.clear_buffer('root') }
			state.register_stream_buffer('root', 'new', 'main', 'chat', 'chat_id', 'keep')
		}
		assert !state.commit_buffer_rollover(claim, 'late', 1000)
		assert !state.cancel_buffer_rollover(claim)
		assert 'late' !in state.buffers
		if scenario != 'clear' {
			assert state.buffers['root'].content == 'keep'
		}
	}
}

fn test_feishu_rollover_failure_preserves_queued_text_for_retry_and_exact_claim_cleanup() {
	mut state := feishu_rollover_state()
	first := state.append_buffer_patch('root', 'main', 'first') or { panic('missing') }
	assert state.append_buffer_patch('root', 'main', ' second') == none
	assert state.cancel_buffer_rollover(first)
	assert !state.cancel_buffer_rollover(first)
	retry := state.append_buffer_patch('root', 'main', ' third') or { panic('missing retry') }
	assert retry.content == 'first second third'
	assert !state.cancel_buffer_rollover(first)
	assert state.append_buffer_patch('root', 'main', ' fourth') == none
	assert state.commit_buffer_rollover(retry, 'next', 1000)
	assert state.buffers['next'].content == 'first second third fourth'
}

fn test_feishu_rollover_result_id_collision_never_overwrites_existing_buffer() {
	mut state := feishu_rollover_state()
	state.register_stream_buffer('foreign', 'other', 'main', '', '', 'keep')
	first := state.append_buffer_patch('root', 'main', 'next') or { panic('missing') }
	assert !state.commit_buffer_rollover(first, 'foreign', 1000)
	assert state.buffers['foreign'].content == 'keep'
	assert state.buffers['root'].next_message_id == ''
	retry := state.append_buffer_patch('root', 'main', '') or { panic('missing retry') }
	assert retry.content == 'next'
	assert state.commit_buffer_rollover(retry, 'safe', 2000)
	assert state.buffers['safe'].content == 'next'
}

fn test_feishu_rollover_patch_does_not_traverse_cycles_missing_or_foreign_links() {
	for target in ['root', 'missing', 'foreign'] {
		mut state := feishu_rollover_state()
		state.register_stream_buffer('foreign', 'other', 'main', '', '', 'keep')
		state.buffers['root'].next_message_id = target
		assert state.append_buffer_patch('root', 'main', 'wrong') == none
		assert state.buffers['foreign'].content == 'keep'
		assert 'missing' !in state.buffers
		assert state.buffers.len == 2
	}
}

fn test_feishu_rollover_registration_resets_old_owner_lifecycle() {
	mut state := feishu_rollover_state()
	old := state.append_buffer_patch('root', 'main', 'unsent') or { panic('missing') }
	state.register_stream_buffer('root', 'new', 'main', '', '', '')
	assert !state.buffers['root'].sealed
	assert state.buffers['root'].next_message_id == ''
	assert state.buffers['root'].content == ''
	assert state.append_buffer_patch('root', 'main', 'new text') == none
	assert state.buffers['root'].content == 'new text'
	assert !state.commit_buffer_rollover(old, 'old-next', 1000)
}

fn test_feishu_rollover_publish_and_session_clear_share_atomic_metadata_boundary() {
	for _ in 0 .. 32 {
		mut app := &App{}
		app.providers.feishu.register_stream_buffer('root', 'stream', 'main', 'chat', 'chat_id', 'finished')
		app.providers.feishu.buffers['root'].sealed = true
		claim := app.providers.feishu.append_buffer_patch('root', 'main', 'next') or { panic('missing') }
		start := chan bool{cap: 2}
		writer := spawn fn [mut app, claim, start] () {
			_ = <-start
			app.feishu_runtime_commit_rollover(claim, 'next')
		}()
		clearer := spawn fn [mut app, claim, start] () {
			_ = <-start
			mut handler := FeishuCommandHandler.new(mut app)
			cmd := transport.WorkerWebSocketUpstreamCommand{
				type_:     'session.clear'
				provider:  'feishu'
				stream_id: 'stream'
				metadata:  {
					'stream_generation': claim.buffer.generation
				}
			}
			mut activity := execmod.WebSocketUpstreamCommandActivity{}
			handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
		}()
		start <- true
		start <- true
		writer.wait()
		clearer.wait()
		assert app.providers.feishu.buffers.len == 0
		assert app.providers.codex.snapshot('main').stream_map.len == 0
	}
}

fn test_feishu_rollover_concurrent_deltas_do_not_create_competing_claims() {
	mut state := feishu_rollover_state()
	claim := state.append_buffer_patch('root', 'main', 'x') or { panic('missing') }
	mut workers := []thread{}
	for _ in 0 .. 16 {
		workers << spawn fn [mut state] () {
			for _ in 0 .. 32 {
				assert state.append_buffer_patch('root', 'main', 'x') == none
			}
		}()
	}
	workers.wait()
	assert state.commit_buffer_rollover(claim, 'next', 1000)
	assert state.buffers['next'].content.len == 513
	assert state.buffers['next'].rendered_content == 'x'
	assert state.buffers.len == 2
}
