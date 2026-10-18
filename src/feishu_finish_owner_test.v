module main

import command
import config
import executor as execmod
import feishu
import upstream.transport

fn feishu_finish_test_app() &App {
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
	app.providers.feishu.register_stream_buffer('root', 'stream', 'main', 'chat', 'chat_id', 'content')
	return app
}

fn test_feishu_finish_registration_is_exclusive_and_cancellation_checks_exact_identity() {
	mut app := feishu_finish_test_app()
	captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
	first := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing claim') }
	assert app.providers.feishu.begin_buffer_finish(captured) == none
	assert app.providers.feishu.cancel_buffer_finish(first)
	assert !app.providers.feishu.cancel_buffer_finish(first)
	next := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing retry') }
	assert !app.providers.feishu.cancel_buffer_finish(first)
	assert app.providers.feishu.buffer_finish_is_current(next)
	assert app.providers.feishu.cancel_buffer_finish(next)
}

fn test_feishu_finish_retirement_rejects_late_segment_publication() {
	for scenario in ['clear', 'rebind', 'recreate'] {
		mut app := feishu_finish_test_app()
		captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
		claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing claim') }
		if scenario == 'clear' {
			app.providers.feishu.clear_stream_buffers('stream')
		} else {
			if scenario == 'recreate' { app.providers.feishu.clear_buffer('root') }
			app.providers.feishu.register_stream_buffer('root', 'new', 'main', '', '', 'keep')
		}
		assert !app.feishu_runtime_publish_finish_segment(claim, 'late')
		assert !app.providers.feishu.commit_buffer_finish_claim(claim, 'old', 2, 1000)
		assert !app.providers.feishu.cancel_buffer_finish(claim)
		assert app.providers.codex.snapshot('main').stream_map.len == 0
	}
}

fn test_feishu_finish_concurrent_delta_rejects_publication_and_can_release_registration() {
	mut app := feishu_finish_test_app()
	captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
	claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing claim') }
	app.providers.feishu.append_buffer_patch('root', 'main', ' new')
	assert !app.providers.feishu.buffer_finish_is_current(claim)
	assert !app.feishu_runtime_publish_finish_segment(claim, 'late')
	assert !app.providers.feishu.commit_buffer_finish_claim(claim, 'old', 2, 1000)
	assert app.providers.feishu.cancel_buffer_finish(claim)
	recent := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
	retry := app.providers.feishu.begin_buffer_finish(recent) or { panic('missing retry') }
	assert app.providers.feishu.commit_buffer_finish_claim(retry, 'content new', 1, 2000)
	assert app.providers.feishu.buffers['root'].sealed
	assert app.providers.feishu.buffers['root'].rendered_content == 'content new'
}

fn test_feishu_active_finish_excludes_preview_and_unregistered_finish_commit() {
	mut app := feishu_finish_test_app()
	app.providers.feishu.buffers['root'].last_flush = 0
	app.providers.feishu.buffers['root'].last_delta = 1000
	captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
	claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing claim') }
	assert app.providers.feishu.pending_buffer_snapshots(2000).len == 0
	assert !app.providers.feishu.buffer_snapshot_is_current(captured)
	assert !app.providers.feishu.commit_buffer_preview(captured, 'preview', 2000)
	assert !app.providers.feishu.commit_buffer_finish(captured, 'unowned', 1, 2000)
	assert app.providers.feishu.commit_buffer_finish_claim(claim, 'final', 1, 2000)
	assert !app.providers.feishu.commit_buffer_preview(captured, 'late', 3000)
	assert !app.providers.feishu.buffer_finish_is_current(claim)
}

fn test_feishu_finish_raw_transport_cannot_publish_targets_from_unowned_metadata() {
	mut app := feishu_finish_test_app()
	result := app.feishu_runtime_send_followup_segment(feishu.StreamBuffer{ message_id: 'unknown', app: 'main', stream_id: 'retired', receive_id: 'chat', receive_id_type: 'chat_id', segment_index: 2 }, 'text', true, '') or { panic(err) }
	assert result == 'om_test_1'
	assert app.providers.codex.snapshot('main').stream_map.len == 0
}

fn test_feishu_retired_finish_does_not_start_another_http_segment() {
	mut app := feishu_finish_test_app()
	captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
	claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing claim') }
	app.providers.feishu.clear_buffer('root')
	mut failed := false
	app.feishu_runtime_send_finish_segment(claim, 'late', true, '', 2) or { failed = true }
	assert failed
	assert app.providers.feishu.http_test_calls == 0
	assert app.providers.codex.snapshot('main').stream_map.len == 0
}

fn test_feishu_finish_segment_publication_and_session_clear_are_serialized() {
	for _ in 0 .. 32 {
		mut app := feishu_finish_test_app()
		captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
		claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing claim') }
		start := chan bool{cap: 2}
		writer := spawn fn [mut app, claim, start] () {
			_ = <-start
			app.feishu_runtime_publish_finish_segment(claim, 'next')
		}()
		clearer := spawn fn [mut app, start] () {
			_ = <-start
			mut handler := FeishuCommandHandler.new(mut app)
			cmd := transport.WorkerWebSocketUpstreamCommand{ type_: 'session.clear', provider: 'feishu', stream_id: 'stream' }
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

fn test_feishu_finish_http_failure_releases_claim_and_successful_split_publishes_targets() {
	mut app := feishu_finish_test_app()
	app.providers.feishu.register_stream_buffer('root', 'stream', 'main', '', '', 'A'.repeat(feishu_stream_buffer_rollover_runes + 10))
	app.providers.feishu.buffers['root'].receive_id = ''
	mut failed := false
	app.feishu_runtime_flush_buffer('root', '', true) or { failed = true }
	assert failed
	captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
	retry := app.providers.feishu.begin_buffer_finish(captured) or { panic('claim leaked') }
	assert app.providers.feishu.cancel_buffer_finish(retry)
	app.providers.feishu.register_stream_buffer('root', 'stream', 'main', 'chat', 'chat_id', '')
	app.feishu_runtime_flush_buffer('root', '', true) or { panic(err) }
	assert app.providers.feishu.buffers['root'].sealed
	assert app.providers.codex.snapshot('main').stream_map['stream'].len == 1
}

fn test_feishu_finish_one_active_registration_rejects_concurrent_end_requests() {
	mut app := feishu_finish_test_app()
	captured := app.providers.feishu.buffer_snapshot('root') or { panic('missing') }
	claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing claim') }
	mut workers := []thread{}
	for _ in 0 .. 16 {
		workers << spawn fn [mut app, captured] () {
			for _ in 0 .. 32 {
				assert app.providers.feishu.begin_buffer_finish(captured) == none
			}
		}()
	}
	workers.wait()
	assert app.providers.feishu.buffer_finish_is_current(claim)
	assert app.providers.feishu.cancel_buffer_finish(claim)
}
