module main

import codex
import command
import config
import executor as execmod
import feishu
import json2 as json
import net.websocket
import time
import upstream
import upstream.transport

@[heap]
struct InitialSendHost {
mut:
	app        &App      = &App{}
	entered    chan bool = chan bool{cap: 1}
	release    chan bool = chan bool{cap: 1}
	generation string
	message_id string = 'late'
	fail       bool
	dispatched int
}

fn (mut h InitialSendHost) websocket_upstream_send(_req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	h.entered <- true
	_ = <-h.release
	if h.fail { return error('http_failed') }
	return upstream.UpstreamSendResult{ ok: true, provider: 'feishu', instance: 'main', message_id: h.message_id }
}

fn (mut _ InitialSendHost) websocket_upstream_update(_req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return error('unused')
}

fn (mut h InitialSendHost) command_feishu_state() &feishu.FeishuState {
	return &h.app.providers.feishu
}

fn (mut h InitialSendHost) codex_find_stream_targets(stream string) []codex.CodexTarget {
	return h.app.codex_find_stream_targets(stream)
}

fn (mut h InitialSendHost) codex_add_stream_target(instance string, stream string, target codex.CodexTarget) {
	h.app.codex_add_stream_target(instance, stream, target)
}

fn (mut h InitialSendHost) codex_rebind_stream_target(instance string, stream string, target codex.CodexTarget) {
	h.app.codex_rebind_stream_target(instance, stream, target)
}

fn (mut h InitialSendHost) codex_resolve_instance_for_stream(stream string) string {
	return h.app.codex_resolve_instance_for_stream(stream)
}

fn (mut h InitialSendHost) codex_clear_stream_targets_any(stream string) bool {
	return h.app.codex_clear_stream_targets_any(stream)
}

fn (mut _ InitialSendHost) feishu_runtime_buffer_patch(_req upstream.UpstreamSendRequest) {}

fn (mut _ InitialSendHost) feishu_runtime_flush_buffer(_id string, _content string, _finish bool) ! {}

fn (mut h InitialSendHost) dispatch_feishu_message_sent(_receipt feishu.SentReceipt) {
	h.dispatched++
}

fn (mut _ InitialSendHost) dispatch_feishu_message_updated(_stream string, _id string) {}

fn (mut _ InitialSendHost) command_feishu_bridge_enabled() bool { return false }

fn (mut _ InitialSendHost) command_feishu_bridge_proxy_append(_req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return error('unused')
}

fn (mut _ InitialSendHost) command_feishu_bridge_proxy_finish(_req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return error('unused')
}

fn (mut _ InitialSendHost) command_feishu_bridge_proxy_fail(_req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return error('unused')
}

fn (mut h InitialSendHost) bridge_context() FeishuCardBridgeContext {
	return h.app.bridge_context()
}

fn initial_send_command(mut host InitialSendHost) execmod.WebSocketUpstreamCommandActivity {
	lease := host.app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	host.generation = lease.generation
	mut handler := FeishuCommandHandler.new(mut host)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:       'provider.message.send'
		provider:    'feishu'
		instance:    'main'
		stream_id:   'stream'
		target:      'chat'
		target_type: 'chat_id'
		text:        'old content'
		metadata:    {
			'stream_generation': lease.generation
			'creation_token':    lease.token
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert handled
	return activity
}

fn initial_send_transition(mut app App, kind string, stream string, id string, pending_generation string) {
	lease := if kind == 'session.bind' && app.providers.feishu.buffer_snapshot(id) == none {
		app.providers.feishu.issue_wire_bind_creation(stream, 'main', id) or { panic(err) }
	} else {
		feishu.CreationLease{}
	}
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:       kind
		provider:    'feishu'
		instance:    'main'
		stream_id:   stream
		target:      id
		target_type: 'message_id'
		metadata:    {
			'creation_generation': lease.generation
			'creation_token':      lease.token
			'stream_generation':   if kind == 'session.bind' {
				(app.providers.feishu.buffer_snapshot(id) or { feishu.StreamBuffer{} }).generation
			} else {
				(app.providers.feishu.buffer_snapshot(id) or { feishu.StreamBuffer{ generation: pending_generation } }).generation
			}
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
}

fn test_initial_send_clear_before_first_buffer_prevents_resurrection() {
	mut host := &InitialSendHost{}
	worker := spawn initial_send_command(mut host)
	_ = <-host.entered
	initial_send_transition(mut host.app, 'session.clear', 'stream', '', host.generation)
	host.release <- true
	activity := worker.wait()
	assert host.app.providers.feishu.buffers.len == 0
	assert host.app.codex_find_stream_targets('stream').len == 0
	assert host.dispatched == 0
	assert activity.message_id == 'late'
	assert activity.error == 'feishu_initial_send_retired'
}

fn test_initial_send_explicit_bind_supersedes_inflight_publication() {
	mut host := &InitialSendHost{}
	worker := spawn initial_send_command(mut host)
	_ = <-host.entered
	initial_send_transition(mut host.app, 'session.bind', 'stream', 'replacement', '')
	host.release <- true
	worker.wait()
	assert host.app.providers.feishu.buffers.len == 1
	assert 'late' !in host.app.providers.feishu.buffers
	assert host.app.codex_find_stream_targets('stream').len == 1
	assert host.dispatched == 0
}

fn test_initial_send_result_id_rebind_preserves_replacement_buffer_and_targets() {
	mut host := &InitialSendHost{}
	worker := spawn initial_send_command(mut host)
	_ = <-host.entered
	initial_send_transition(mut host.app, 'session.bind', 'new-stream', 'late', '')
	host.app.providers.feishu.register_stream_buffer('late', 'new-stream', 'main', '', '', 'replacement content')
	host.release <- true
	worker.wait()
	assert host.app.providers.feishu.buffers['late'].stream_id == 'new-stream'
	assert host.app.providers.feishu.buffers['late'].content == 'replacement content'
	assert host.app.codex_find_stream_targets('stream').len == 0
	assert host.app.codex_find_stream_targets('new-stream').len == 1
	assert host.dispatched == 0
}

fn test_initial_send_old_completion_cannot_reacquire_after_clear_and_new_send() {
	mut app := &App{}
	mut old := &InitialSendHost{ app: app, message_id: 'old' }
	first := spawn initial_send_command(mut old)
	_ = <-old.entered
	initial_send_transition(mut app, 'session.clear', 'stream', '', old.generation)
	mut fresh := &InitialSendHost{ app: app, message_id: 'fresh' }
	second := spawn initial_send_command(mut fresh)
	_ = <-fresh.entered
	fresh.release <- true
	second.wait()
	old.release <- true
	first.wait()
	assert app.providers.feishu.buffers.len == 1
	assert 'fresh' in app.providers.feishu.buffers
	assert app.codex_find_stream_targets('stream').len == 1
	assert old.dispatched == 0
	assert fresh.dispatched == 1
}

fn test_initial_send_parallel_current_results_both_publish() {
	mut app := &App{}
	mut one := &InitialSendHost{ app: app, message_id: 'one' }
	mut two := &InitialSendHost{ app: app, message_id: 'two' }
	first := spawn initial_send_command(mut one)
	second := spawn initial_send_command(mut two)
	_ = <-one.entered
	_ = <-two.entered
	two.release <- true
	second.wait()
	one.release <- true
	first.wait()
	assert app.providers.feishu.buffers.len == 2
	assert app.codex_find_stream_targets('stream').len == 2
	assert one.dispatched == 1 && two.dispatched == 1
}

fn test_initial_send_http_error_releases_admission_and_retry_publishes() {
	mut app := &App{}
	mut failed := &InitialSendHost{ app: app, fail: true }
	failed.release <- true
	activity := initial_send_command(mut failed)
	assert activity.error == 'http_failed'
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets('stream').len == 0
	mut retry := &InitialSendHost{ app: app, message_id: 'retry' }
	retry.release <- true
	assert initial_send_command(mut retry).status == 'sent'
	assert app.codex_find_stream_targets('stream').len == 1
}

fn initial_send_bridge(mut host InitialSendHost) {
	lease := host.app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	host.generation = lease.generation
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	state := bridge_authority_test_server(mut host, client)
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeProxyRequest{
			type_:      feishu.bridge_proxy_request_type
			request_id: 'initial'
			action:     'send'
			request:    upstream.UpstreamSendRequest{
				provider:    'feishu'
				instance:    'main'
				target:      'chat'
				target_type: 'chat_id'
				text:        'old'
				metadata:    {
					'stream_id':         'stream'
					'stream_generation': lease.generation
					'creation_token':    lease.token
				}
			}
		}).bytes()
	}, state) or { panic(err) }
}

fn test_initial_send_bridge_completion_respects_clear_rebind_and_id_collision() {
	for scenario in ['clear', 'bind', 'collision'] {
		mut host := &InitialSendHost{}
		worker := spawn initial_send_bridge(mut host)
		_ = <-host.entered
		if scenario == 'clear' {
			initial_send_transition(mut host.app, 'session.clear', 'stream', '', host.generation)
		} else {
			initial_send_transition(mut host.app, 'session.bind', if scenario == 'bind' {
				'stream'
			} else {
				'new-stream'
			}, if scenario == 'bind' { 'replacement' } else { 'late' }, '')
		}
		host.release <- true
		worker.wait()
		assert host.app.providers.feishu.buffers.len == if scenario == 'clear' { 0 } else { 1 }
		if scenario == 'collision' {
			assert host.app.providers.feishu.buffers['late'].stream_id == 'new-stream'
		} else {
			assert 'late' !in host.app.providers.feishu.buffers
		}
	}
}

fn test_initial_send_real_http_adapter_completion_cannot_revive_cleared_stream() {
	mut app := &App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled:            true
				open_base_url:      'https://open.feishu.test/open-apis'
				apps:               {
					'main': config.FeishuAppConfig{ app_id: 'cli', app_secret: 'secret' }
				}
				http_test_stub:     true
				http_test_delay_ms: 250
			}
		}
	}
	lease := app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	worker := spawn fn [mut app, lease] () {
		mut handler := FeishuCommandHandler.new(mut app)
		cmd := transport.WorkerWebSocketUpstreamCommand{
			type_:       'provider.message.send'
			provider:    'feishu'
			instance:    'main'
			stream_id:   'stream'
			target:      'chat'
			target_type: 'chat_id'
			text:        'content'
			metadata:    {
				'stream_generation': lease.generation
				'creation_token':    lease.token
			}
		}
		mut activity := execmod.WebSocketUpstreamCommandActivity{}
		handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	}()
	deadline := time.now().unix_milli() + 3000
	mut entered := false
	for time.now().unix_milli() < deadline {
		app.providers.feishu.http_test_mu.@lock()
		entered = app.providers.feishu.http_test_inflight > 0
		app.providers.feishu.http_test_mu.unlock()
		if entered { break }
		time.sleep(time.millisecond)
	}
	initial_send_transition(mut app, 'session.clear', 'stream', '', lease.generation)
	worker.wait()
	assert entered
	assert app.providers.feishu.http_test_calls >= 2
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets('stream').len == 0
}

fn test_initial_send_rebound_then_deleted_result_id_cannot_be_recreated() {
	for bridge in [false, true] {
		mut host := &InitialSendHost{}
		if bridge {
			worker := spawn initial_send_bridge(mut host)
			_ = <-host.entered
			initial_send_transition(mut host.app, 'session.bind', 'new-stream', 'late', '')
			initial_send_transition(mut host.app, 'session.clear', 'new-stream', 'late', '')
			host.release <- true
			worker.wait()
		} else {
			worker := spawn initial_send_command(mut host)
			_ = <-host.entered
			initial_send_transition(mut host.app, 'session.bind', 'new-stream', 'late', '')
			initial_send_transition(mut host.app, 'session.clear', 'new-stream', 'late', '')
			host.release <- true
			worker.wait()
		}
		assert host.app.providers.feishu.buffers.len == 0
		assert host.app.codex_find_stream_targets('stream').len == 0
		assert host.app.codex_find_stream_targets('new-stream').len == 0
	}
}

fn test_initial_send_completion_and_clear_publish_or_retire_as_one_transition() {
	for _ in 0 .. 32 {
		mut host := &InitialSendHost{}
		worker := spawn initial_send_command(mut host)
		_ = <-host.entered
		mut app := host.app
		generation := host.generation
		clearer := spawn fn [mut app, generation] () {
			initial_send_transition(mut app, 'session.clear', 'stream', '', generation)
		}()
		host.release <- true
		worker.wait()
		clearer.wait()
		assert app.providers.feishu.buffers.len == 0
		assert app.codex_find_stream_targets('stream').len == 0
	}
}

fn (mut h InitialSendHost) feishu_runtime_execute_stream_command(admission feishu.StreamCommand, req upstream.UpstreamSendRequest, action string, finish bool) !upstream.UpstreamUpdateResult {
	return h.app.feishu_runtime_execute_stream_command(admission, req, action, finish)
}

fn (mut h InitialSendHost) codex_release_feishu_targets(released feishu.WireStreamRelease) {
	h.app.codex_release_feishu_targets(released)
}
