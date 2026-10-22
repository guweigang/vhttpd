module main

import config
import feishu
import upstream

fn test_feishu_buffer_commit_rejects_rebind_and_same_id_recreation() {
	mut state := feishu.FeishuState{}
	state.register_stream_buffer('message', 'old', 'main', '', '', 'old')
	old := state.buffer_snapshot('message') or { panic('missing') }
	state.register_stream_buffer('message', 'new', 'main', '', '', 'new')
	assert !state.commit_buffer_preview(old, 'old', 5000)
	assert !state.commit_buffer_finish(old, 'old', 1, 5000)
	assert state.buffers['message'].content == 'new'
	assert state.buffers['message'].rendered_content == 'new'
	current := state.buffer_snapshot('message') or { panic('missing') }
	state.clear_buffer('message')
	state.register_stream_buffer('message', 'new', 'main', '', '', 'new')
	assert !state.buffer_snapshot_is_current(current)
	assert !state.commit_buffer_preview(current, 'stale', 6000)
}

fn test_feishu_preview_commit_preserves_concurrent_same_tick_delta_for_next_flush() {
	mut app := &App{}
	app.providers.feishu.buffers['message'] = feishu.StreamBuffer{ message_id: 'message', stream_id: 'stream', content: 'first', last_delta: 1000, last_flush: 0 }
	old := app.providers.feishu.buffer_snapshot('message') or { panic('missing') }
	app.feishu_runtime_buffer_patch(upstream.UpstreamSendRequest{ target: 'message', text: ' second' })
	// Timestamp equality must not mark the unsent suffix as flushed.
	app.providers.feishu.buffers['message'].last_delta = 1000
	assert app.providers.feishu.commit_buffer_preview(old, 'first', 2000)
	active := app.providers.feishu.buffers['message']
	assert active.content == 'first second'
	assert active.rendered_content == 'first'
	assert active.last_flush == 0
	pending := app.providers.feishu.pending_buffer_snapshots(3000)
	assert pending.len == 1
	assert pending[0].content == 'first second'
	assert app.providers.feishu.commit_buffer_preview(pending[0], 'first second', 3000)
	assert app.providers.feishu.pending_buffer_snapshots(4000).len == 0
}

fn test_feishu_older_preview_completion_cannot_overwrite_newer_commit() {
	mut state := feishu.FeishuState{
		buffers: {
			'message': feishu.StreamBuffer{ message_id: 'message', content: 'first', last_flush: 0, last_delta: 1000 }
		}
	}
	old := state.buffer_snapshot('message') or { panic('missing') }
	state.buffers['message'].content += ' second'
	recent := state.buffer_snapshot('message') or { panic('missing') }
	assert state.commit_buffer_preview(recent, 'first second', 2000)
	assert !state.commit_buffer_preview(old, 'first', 3000)
	assert state.buffers['message'].rendered_content == 'first second'
	assert state.buffers['message'].last_flush == 2000
}

fn test_feishu_finish_commit_rejects_unsent_delta_and_retires_late_preview() {
	mut state := feishu.FeishuState{
		buffers: {
			'message': feishu.StreamBuffer{ message_id: 'message', content: 'first', last_flush: 0, last_delta: 1000 }
		}
	}
	old := state.buffer_snapshot('message') or { panic('missing') }
	state.buffers['message'].content += ' second'
	assert !state.commit_buffer_finish(old, 'first', 1, 2000)
	assert !state.buffers['message'].sealed
	assert state.buffers['message'].content == 'first second'
	recent := state.buffer_snapshot('message') or { panic('missing') }
	assert state.commit_buffer_finish(recent, 'first second', 2, 3000)
	assert state.buffers['message'].sealed
	assert state.buffers['message'].content == ''
	assert state.buffers['message'].segment_index == 2
	assert !state.commit_buffer_preview(recent, 'preview', 4000)
	assert state.buffers['message'].rendered_content == 'first second'
	assert state.pending_buffer_snapshots(5000).len == 0
}

fn test_feishu_unowned_values_cannot_authorize_buffer_commits() {
	mut state := feishu.FeishuState{
		buffers: {
			'message': feishu.StreamBuffer{ message_id: 'message', content: 'text', last_flush: 0, last_delta: 1000 }
		}
	}
	fabricated := state.buffers['message']
	assert !state.commit_buffer_preview(fabricated, 'stale', 2000)
	assert !state.commit_buffer_finish(fabricated, 'stale', 1, 2000)
	captured := state.pending_buffer_snapshots(2000)
	assert captured.len == 1
	assert state.buffer_snapshot_is_current(captured[0])
	assert state.commit_buffer_preview(captured[0], 'text', 2000)
	state.clear_buffer('message')
	assert !state.commit_buffer_preview(captured[0], 'text', 3000)
	assert !state.commit_buffer_finish(captured[0], 'text', 1, 3000)
	assert state.buffers.len == 0
}

fn test_feishu_finish_does_not_delete_unowned_followup_message_buffer() {
	mut app := &App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled:        true
				open_base_url:  'https://open.feishu.test/open-apis'
				apps:           {
					'main': config.FeishuAppConfig{ app_id: 'cli_main', app_secret: 'sec_main' }
				}
				http_test_stub: true
			}
		}
	}
	app.providers.feishu.register_stream_buffer('root', '', 'main', 'chat', 'chat_id', 'A'.repeat(feishu_stream_buffer_rollover_runes + 10))
	// The send fixture returns om_test_1. Sending a followup does not grant this
	// operation ownership of a pre-existing buffer with the returned message ID.
	app.providers.feishu.register_stream_buffer('om_test_1', 'other', 'main', '', '', 'keep')
	app.feishu_runtime_flush_buffer('root', '', true) or { panic(err) }
	assert app.providers.feishu.buffers['root'].sealed
	assert app.providers.feishu.buffers['om_test_1'].stream_id == 'other'
	assert app.providers.feishu.buffers['om_test_1'].content == 'keep'
}

fn test_feishu_concurrent_buffer_rebinds_reject_old_callbacks() {
	mut state := &feishu.FeishuState{}
	mut workers := []thread{}
	for worker in 0 .. 16 {
		workers << spawn fn [mut state, worker] () {
			for index in 0 .. 32 {
				key := '${worker}-${index}'
				state.register_stream_buffer(key, 'old', 'main', '', '', 'old')
				old := state.buffer_snapshot(key) or { panic('missing') }
				state.register_stream_buffer(key, 'new', 'main', '', '', 'new')
				assert !state.commit_buffer_preview(old, 'old', 10000)
				assert !state.commit_buffer_finish(old, 'old', 1, 10000)
			}
		}()
	}
	workers.wait()
	assert state.buffers.len == 512
	for _, buf in state.buffers {
		assert buf.content == 'new'
		assert buf.rendered_content == 'new'
		assert !buf.sealed
	}
}
