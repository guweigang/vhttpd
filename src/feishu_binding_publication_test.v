module main

import codex
import command
import executor as execmod
import feishu
import time
import upstream.transport

fn binding_publication_command(mut app App, kind string, stream string, message string) {
	lease := if kind == 'session.bind' && app.providers.feishu.buffer_snapshot(message) == none {
		app.providers.feishu.issue_wire_bind_creation(stream, 'main', message) or { panic(err) }
	} else {
		feishu.CreationLease{}
	}
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:       kind
		provider:    'feishu'
		instance:    'main'
		stream_id:   stream
		target:      message
		target_type: 'message_id'
		metadata:    {
			'creation_generation': lease.generation
			'creation_token':      lease.token
			'stream_generation':   if message != '' {
				(app.providers.feishu.buffer_snapshot(message) or { feishu.StreamBuffer{} }).generation
			} else {
				''
			}
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert handled
	assert err == ''
}

fn test_feishu_bind_cannot_publish_target_before_buffer_owner_admission() {
	mut app := &App{}
	started := chan bool{cap: 1}
	app.providers.feishu.mu.@lock()
	writer := spawn fn [mut app, started] () {
		started <- true
		binding_publication_command(mut app, 'session.bind', 'stream', 'message')
	}()
	_ = <-started
	mut leaked := false
	deadline := time.now().unix_milli() + 150
	for time.now().unix_milli() < deadline {
		if app.codex_find_stream_targets('stream').len > 0 {
			leaked = true
			break
		}
		time.sleep(time.millisecond)
	}
	// Execute the same state-only retirement as session.clear under its actual
	// owner lock. A pending bind must linearize wholly before or after this.
	app.providers.feishu.clear_stream_buffers_unlocked('stream')
	app.codex_clear_stream_targets_any('stream')
	app.providers.feishu.mu.unlock()
	writer.wait()
	assert app.providers.feishu.buffers['message'].stream_id == 'stream'
	assert app.codex_find_stream_targets('stream').len == 1
	assert !leaked
}

fn test_feishu_bind_transfers_only_matching_message_across_codex_instances() {
	mut app := &App{}
	binding_publication_command(mut app, 'session.bind', 'old', 'message')
	app.codex_add_stream_target('main', 'old', codex.CodexTarget{ platform: 'feishu', message_id: 'other' })
	app.codex_add_stream_target('secondary', 'other-stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message' })
	app.codex_add_stream_target('secondary', 'other-stream', codex.CodexTarget{ platform: 'other', message_id: 'message' })
	binding_publication_command(mut app, 'session.bind', 'new', 'message')
	assert app.providers.feishu.buffers['message'].stream_id == 'new'
	old := app.codex_find_stream_targets('old')
	assert old.len == 1
	assert old[0].message_id == 'other'
	secondary := app.codex_stream_targets('secondary', 'other-stream')
	assert secondary.len == 1
	assert secondary[0].platform == 'other'
	assert app.codex_find_stream_targets('new').len == 1
}

fn test_feishu_bind_repeated_registration_publishes_one_target() {
	mut app := &App{}
	for _ in 0 .. 4 {
		binding_publication_command(mut app, 'session.bind', 'stream', 'message')
	}
	assert app.codex_find_stream_targets('stream').len == 1
	assert app.providers.feishu.buffers.len == 1
}

fn test_feishu_bind_and_clear_concurrently_leave_paired_registries() {
	for _ in 0 .. 64 {
		mut app := &App{}
		start := chan bool{cap: 2}
		binder := spawn fn [mut app, start] () {
			_ = <-start
			binding_publication_command(mut app, 'session.bind', 'stream', 'message')
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
		binder.wait()
		clearer.wait()
		assert app.providers.feishu.buffers.len == app.codex_find_stream_targets('stream').len
	}
}

fn test_feishu_rebind_retires_captured_rollover_completion() {
	mut app := &App{}
	binding_publication_command(mut app, 'session.bind', 'old', 'message')
	app.providers.feishu.register_stream_buffer('message', 'old', 'main', 'chat', 'chat_id', 'done')
	app.providers.feishu.buffers['message'].sealed = true
	claim := app.providers.feishu.append_buffer_patch('message', 'main', 'late') or { panic('missing claim') }
	binding_publication_command(mut app, 'session.bind', 'new', 'message')
	assert !app.feishu_runtime_commit_rollover(claim, 'late-message')
	assert 'late-message' !in app.providers.feishu.buffers
	assert app.codex_find_stream_targets('old').len == 0
	assert app.codex_find_stream_targets('new').len == 1
}

fn test_feishu_rebind_then_clear_retires_captured_finish_completion() {
	mut app := &App{}
	binding_publication_command(mut app, 'session.bind', 'old', 'message')
	app.providers.feishu.register_stream_buffer('message', 'old', 'main', 'chat', 'chat_id', 'done')
	captured := app.providers.feishu.buffer_snapshot('message') or { panic('missing buffer') }
	claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('missing finish') }
	binding_publication_command(mut app, 'session.bind', 'new', 'message')
	assert !app.feishu_runtime_publish_finish_segment(claim, 'late-before-clear')
	binding_publication_command(mut app, 'session.clear', 'new', 'message')
	assert !app.feishu_runtime_publish_finish_segment(claim, 'late-after-clear')
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets('new').len == 0
	assert app.codex_find_stream_targets('old').len == 0
}
