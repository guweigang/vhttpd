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
struct StreamAdmissionHost {
mut:
	app            &App = &App{}
	mode           string
	updated        int
	notified       int
	bridge         bool
	after_proxy    string
	proxy_calls    int
	proxy_metadata map[string]string
	proxy_instance string
}

fn (mut h StreamAdmissionHost) retire() {
	mode := h.mode
	h.mode = ''
	if mode in ['clear', 'recreate'] { h.app.providers.feishu.clear_stream_buffers('stream') }
	if mode in ['rebind', 'recreate', 'other'] {
		h.app.providers.feishu.register_stream_buffer('message', if mode == 'other' {
			'new-stream'
		} else {
			'stream'
		}, 'main', 'chat', 'chat_id', 'replacement')
	}
}

fn (mut _ StreamAdmissionHost) websocket_upstream_send(_req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	return error('unused')
}

fn (mut h StreamAdmissionHost) websocket_upstream_update(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	h.retire()
	h.updated++
	return upstream.UpstreamUpdateResult{ ok: true, message_id: req.target }
}

fn (mut h StreamAdmissionHost) command_feishu_state() &feishu.FeishuState {
	return &h.app.providers.feishu
}

fn (mut h StreamAdmissionHost) codex_find_stream_targets(stream string) []codex.CodexTarget {
	return h.app.codex_find_stream_targets(stream)
}

fn (mut h StreamAdmissionHost) codex_add_stream_target(instance string, stream string, target codex.CodexTarget) {
	h.app.codex_add_stream_target(instance, stream, target)
}

fn (mut h StreamAdmissionHost) codex_rebind_stream_target(instance string, stream string, target codex.CodexTarget) {
	h.app.codex_rebind_stream_target(instance, stream, target)
}

fn (mut h StreamAdmissionHost) codex_resolve_instance_for_stream(stream string) string {
	return h.app.codex_resolve_instance_for_stream(stream)
}

fn (mut h StreamAdmissionHost) codex_clear_stream_targets_any(stream string) bool {
	return h.app.codex_clear_stream_targets_any(stream)
}

fn (mut h StreamAdmissionHost) feishu_runtime_buffer_patch(req upstream.UpstreamSendRequest) {
	h.retire()
	h.app.feishu_runtime_buffer_patch(req)
}

fn (mut h StreamAdmissionHost) feishu_runtime_flush_buffer(id string, content string, finish bool) ! {
	h.retire()
	h.app.feishu_runtime_flush_buffer(id, content, finish)!
}

fn (mut h StreamAdmissionHost) dispatch_feishu_message_sent(_receipt feishu.SentReceipt) {
	h.notified++
}

fn (mut h StreamAdmissionHost) dispatch_feishu_message_updated(_stream string, _id string) {
	h.notified++
}

fn (mut h StreamAdmissionHost) command_feishu_bridge_enabled() bool {
	h.retire()
	return h.bridge
}

fn (mut h StreamAdmissionHost) command_feishu_bridge_proxy_append(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return h.proxy(req, 'append')
}

fn (mut h StreamAdmissionHost) command_feishu_bridge_proxy_finish(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return h.proxy(req, 'finish')
}

fn (mut h StreamAdmissionHost) command_feishu_bridge_proxy_fail(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return h.proxy(req, 'fail')
}

fn (mut h StreamAdmissionHost) bridge_context() FeishuCardBridgeContext {
	return h.app.bridge_context()
}

fn stream_admission_host(mode string) &StreamAdmissionHost {
	mut host := &StreamAdmissionHost{
		mode: mode
		app:  &App{
			providers: ProviderRuntimeHub{
				feishu: feishu.FeishuState{
					enabled:        true
					open_base_url:  'https://open.feishu.test/open-apis'
					apps:           {
						'main': config.FeishuAppConfig{ app_id: 'cli', app_secret: 'secret' }
					}
					http_test_stub: true
				}
			}
		}
	}
	host.app.providers.feishu.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'old')
	return host
}

fn stream_admission_execute(mut host StreamAdmissionHost, action string, stream string, id string, instance string) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut host)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:        'stream.${action}'
		provider:     'feishu'
		message_type: 'interactive'
		content:      if action == 'fail' {
			feishu.SendMessageRequest.interactive_markdown_card('failed')
		} else {
			''
		}
		instance:     instance
		stream_id:    stream
		target:       id
		target_type:  'message_id'
		text:         'late'
		metadata:     {
			'finish':            'true'
			'stream_generation': (host.app.providers.feishu.buffer_snapshot(id) or { feishu.StreamBuffer{} }).generation
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert handled
	return activity
}

fn stream_admission_assert_rejected(host &StreamAdmissionHost, activity execmod.WebSocketUpstreamCommandActivity, missing bool) {
	if missing {
		assert host.app.providers.feishu.buffers.len == 0
	} else {
		assert host.app.providers.feishu.buffers['message'].content == 'replacement'
		assert !host.app.providers.feishu.buffers['message'].sealed
	}
	assert host.updated == 0
	assert host.app.providers.feishu.http_test_calls == 0
	assert host.notified == 0
	assert activity.error == 'feishu_stream_command_retired'
}

fn stream_admission_old_stream(action string) {
	mut host := stream_admission_host('')
	host.app.providers.feishu.register_stream_buffer('message', 'new-stream', 'main', 'chat', 'chat_id', 'replacement')
	activity := stream_admission_execute(mut host, action, 'stream', 'message', 'main')
	stream_admission_assert_rejected(host, activity, false)
}

fn test_stream_old_append_cannot_mutate_rebound_message() { stream_admission_old_stream('append') }

fn test_stream_old_finish_cannot_seal_rebound_message() { stream_admission_old_stream('finish') }

fn test_stream_old_fail_cannot_delete_rebound_message() { stream_admission_old_stream('fail') }

fn stream_admission_gate(action string) {
	for mode in ['rebind', 'clear', 'recreate'] {
		mut host := stream_admission_host(mode)
		activity := stream_admission_execute(mut host, action, 'stream', 'message', 'main')
		stream_admission_assert_rejected(host, activity, mode == 'clear')
	}
}

fn test_stream_admitted_append_revalidates_same_stream_identity() {
	stream_admission_gate('append')
}

fn test_stream_admitted_finish_revalidates_same_stream_identity() {
	stream_admission_gate('finish')
}

fn test_stream_admitted_fail_revalidates_same_stream_identity() { stream_admission_gate('fail') }

fn test_stream_commands_cannot_recreate_withdrawn_buffer() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('')
		host.app.providers.feishu.clear_buffer('message')
		activity := stream_admission_execute(mut host, action, 'stream', 'message', 'main')
		stream_admission_assert_rejected(host, activity, true)
	}
}

fn test_stream_missing_target_never_falls_through_to_message_update() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('')
		activity := stream_admission_execute(mut host, action, 'stream', '', 'main')
		assert host.updated == 0
		assert activity.error == 'feishu_stream_command_retired'
		assert host.app.providers.feishu.buffers['message'].content == 'old'
	}
}

fn stream_admission_bridge(mut host StreamAdmissionHost, action string) {
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	state := bridge_authority_test_server(mut host, client)
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeProxyRequest{
			type_:      feishu.bridge_proxy_request_type
			request_id: 'stream-command'
			action:     action
			request:    upstream.UpstreamSendRequest{
				provider:    'feishu'
				instance:    'main'
				target:      'message'
				target_type: 'message_id'
				text:        'late'
				metadata:    {
					'stream_id':         'stream'
					'stream_generation': (host.app.providers.feishu.buffer_snapshot('message') or { feishu.StreamBuffer{} }).generation
				}
			}
		}).bytes()
	}, state) or { panic(err) }
}

fn test_stream_bridge_rejects_old_stream_for_each_operation() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('')
		host.app.providers.feishu.register_stream_buffer('message', 'new-stream', 'main', '', '', 'replacement')
		stream_admission_bridge(mut host, action)
		assert host.app.providers.feishu.buffers['message'].content == 'replacement'
		assert !host.app.providers.feishu.buffers['message'].sealed
		assert host.updated == 0
		assert host.app.providers.feishu.http_test_calls == 0
	}
}

fn test_stream_bridge_carries_admitted_identity_into_runtime_operation() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('rebind')
		stream_admission_bridge(mut host, action)
		assert host.app.providers.feishu.buffers['message'].content == 'replacement'
		assert !host.app.providers.feishu.buffers['message'].sealed
		assert host.updated == 0
		assert host.app.providers.feishu.http_test_calls == 0
	}
}

fn test_stream_current_commands_keep_append_finish_and_fail_behavior() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('')
		activity := stream_admission_execute(mut host, action, 'stream', 'message', 'main')
		assert activity.error == ''
		if action == 'append' {
			assert host.app.providers.feishu.buffers['message'].content == 'oldlate'
		}
		if action == 'finish' {
			assert host.app.providers.feishu.buffers['message'].sealed
		}
		if action == 'fail' {
			assert 'message' !in host.app.providers.feishu.buffers
		}
	}
}

fn test_stream_bound_buffer_rejects_missing_stream_or_wrong_app() {
	for variant in ['no-stream', 'wrong-app'] {
		mut host := stream_admission_host('')
		activity := stream_admission_execute(mut host, 'append', if variant == 'no-stream' {
			''
		} else {
			'stream'
		}, 'message', if variant == 'wrong-app' { 'other' } else { 'main' })
		assert host.app.providers.feishu.buffers['message'].content == 'old'
		assert activity.error == 'feishu_stream_command_retired'
	}
}

fn (mut h StreamAdmissionHost) feishu_runtime_execute_stream_command(admission feishu.StreamCommand, req upstream.UpstreamSendRequest, action string, finish bool) !upstream.UpstreamUpdateResult {
	h.retire()
	return h.app.feishu_runtime_execute_stream_command(admission, req, action, finish)
}

fn (mut h StreamAdmissionHost) proxy(req upstream.UpstreamSendRequest, action string) !upstream.UpstreamUpdateResult {
	h.proxy_calls++
	h.proxy_metadata = req.metadata.clone()
	h.proxy_instance = req.instance
	h.mode = h.after_proxy
	h.retire()
	return upstream.UpstreamUpdateResult{
		ok:                true
		provider:          'feishu'
		instance:          'main'
		message_id:        req.target
		stream_generation: req.metadata['stream_generation'] or { '' }
		stream_state:      if action == 'fail' {
			'removed'
		} else {
			'open'
		}
	}
}

fn test_stream_fail_http_completion_cannot_remove_rebound_generation() {
	mut host := stream_admission_host('')
	host.app.providers.feishu.http_test_delay_ms = 200
	worker := spawn stream_admission_execute(mut host, 'fail', 'stream', 'message', 'main')
	deadline := time.now().unix_milli() + 3000
	mut entered := false
	for time.now().unix_milli() < deadline {
		host.app.providers.feishu.http_test_mu.@lock()
		entered = host.app.providers.feishu.http_test_inflight > 0
		host.app.providers.feishu.http_test_mu.unlock()
		if entered { break }
		time.sleep(time.millisecond)
	}
	host.app.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'replacement')
	assert stream_admission_execute(mut host, 'append', 'stream', 'message', 'main').error == ''
	activity := worker.wait()
	assert entered
	assert activity.error == 'feishu_stream_command_retired'
	assert host.app.providers.feishu.buffers['message'].content == 'replacementlate'
	assert !host.app.providers.feishu.buffers['message'].sealed
	assert host.notified == 0
}

fn test_stream_bridge_client_rejects_retired_admission_before_proxy() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('rebind')
		host.bridge = true
		activity := stream_admission_execute(mut host, action, 'stream', 'message', 'main')
		stream_admission_assert_rejected(host, activity, false)
		assert host.proxy_calls == 0
	}
}

fn test_stream_bridge_client_rechecks_identity_after_proxy_completion() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('')
		host.bridge = true
		host.after_proxy = 'rebind'
		activity := stream_admission_execute(mut host, action, 'stream', 'message', 'main')
		stream_admission_assert_rejected(host, activity, false)
		assert host.proxy_calls == 1
	}
}

fn test_stream_bridge_client_transmits_context_and_preserves_preview_mode() {
	mut host := stream_admission_host('')
	host.bridge = true
	mut handler := FeishuCommandHandler.new(mut host)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:       'stream.finish'
		provider:    'feishu'
		instance:    ''
		stream_id:   'stream'
		target:      'message'
		target_type: 'message_id'
		metadata:    {
			'stream_generation': (host.app.providers.feishu.buffer_snapshot('message') or { panic('missing') }).generation
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert activity.error == ''
	assert activity.status == 'flushed'
	assert host.proxy_metadata['stream_id'] == 'stream'
	assert host.proxy_instance == 'main'
	assert host.proxy_metadata['feishu_stream_finish'] == 'false'
	assert 'stream_id' !in cmd.metadata
}

fn test_stream_bridge_client_current_fail_retires_its_own_mirror() {
	mut host := stream_admission_host('')
	host.bridge = true
	activity := stream_admission_execute(mut host, 'fail', 'stream', 'message', 'main')
	assert activity.error == ''
	assert activity.status == 'failed'
	assert host.proxy_calls == 1
	assert host.app.providers.feishu.buffers.len == 0
	assert host.notified == 1
}

fn test_stream_bridge_server_preview_does_not_seal_current_buffer() {
	mut host := stream_admission_host('')
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	state := bridge_authority_test_server(mut host, client)
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeProxyRequest{
			type_:      feishu.bridge_proxy_request_type
			request_id: 'preview'
			action:     'finish'
			request:    upstream.UpstreamSendRequest{
				provider: 'feishu'
				instance: 'main'
				target:   'message'
				metadata: {
					'stream_id':            'stream'
					'stream_generation':    (host.app.providers.feishu.buffer_snapshot('message') or { feishu.StreamBuffer{} }).generation
					'feishu_stream_finish': 'false'
				}
			}
		}).bytes()
	}, state) or { panic(err) }
	assert !host.app.providers.feishu.buffers['message'].sealed
	assert host.app.providers.feishu.buffers['message'].content == 'old'
	assert host.app.providers.feishu.http_test_calls >= 2
}

fn test_stream_canonical_kind_cannot_bypass_admission_using_legacy_event() {
	for event in ['send', 'ignored'] {
		mut host := stream_admission_host('')
		host.app.providers.feishu.register_stream_buffer('message', 'new-stream', 'main', '', '', 'replacement')
		mut handler := FeishuCommandHandler.new(mut host)
		cmd := transport.WorkerWebSocketUpstreamCommand{ type_: 'stream.fail', event: event, provider: 'feishu', instance: 'main', stream_id: 'stream', target: 'message' }
		mut activity := execmod.WebSocketUpstreamCommandActivity{}
		handled, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
		assert handled
		stream_admission_assert_rejected(host, activity, false)
	}
}

fn test_stream_wire_generation_rejects_packets_created_before_identical_rebind() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('')
		old := host.app.providers.feishu.buffer_snapshot('message') or { panic('missing') }
		packet := transport.WorkerWebSocketUpstreamCommand{
			type_:       'stream.${action}'
			provider:    'feishu'
			instance:    'main'
			stream_id:   'stream'
			target:      'message'
			target_type: 'message_id'
			text:        'late'
			metadata:    {
				'stream_generation': old.generation
			}
		}
		host.app.providers.feishu.clear_buffer('message')
		host.app.providers.feishu.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'replacement')
		mut handler := FeishuCommandHandler.new(mut host)
		mut activity := execmod.WebSocketUpstreamCommandActivity{}
		handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
		assert handled
		stream_admission_assert_rejected(host, activity, false)
		assert stream_admission_execute(mut host, 'append', 'stream', 'message', 'main').error == ''
	}
}

fn test_stream_wire_generation_missing_or_wrong_never_authorizes_current_buffer() {
	for action in ['append', 'finish', 'fail'] {
		for generation in ['', 'foreign'] {
			mut host := stream_admission_host('')
			packet := transport.WorkerWebSocketUpstreamCommand{
				type_:     'stream.${action}'
				provider:  'feishu'
				stream_id: 'stream'
				target:    'message'
				text:      'late'
				metadata:  {
					'stream_generation': generation
				}
			}
			mut handler := FeishuCommandHandler.new(mut host)
			mut activity := execmod.WebSocketUpstreamCommandActivity{}
			handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
			assert handled
			assert activity.error == 'feishu_stream_command_retired'
			assert host.app.providers.feishu.buffers['message'].content == 'old'
			assert host.app.providers.feishu.http_test_calls == 0
		}
	}
}

fn test_bridge_wire_generation_cannot_refresh_a_stale_packet_at_ingress() {
	for action in ['append', 'finish', 'fail'] {
		mut host := stream_admission_host('')
		old := host.app.providers.feishu.buffer_snapshot('message') or { panic('missing') }
		packet := json.encode(feishu.BridgeProxyRequest{
			type_:      feishu.bridge_proxy_request_type
			request_id: 'old-generation'
			action:     action
			request:    upstream.UpstreamSendRequest{
				provider: 'feishu'
				instance: 'main'
				target:   'message'
				text:     'late'
				metadata: {
					'stream_id':         'stream'
					'stream_generation': old.generation
				}
			}
		})
		host.app.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'replacement')
		mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
		state := bridge_authority_test_server(mut host, client)
		feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
			opcode:  .text_frame
			payload: packet.bytes()
		}, state) or { panic(err) }
		assert host.app.providers.feishu.buffers['message'].content == 'replacement'
		assert !host.app.providers.feishu.buffers['message'].sealed
		assert host.app.providers.feishu.http_test_calls == 0
	}
}

fn test_bind_receipt_rotates_generation_even_when_all_identifiers_match() {
	mut host := stream_admission_host('')
	old := host.app.providers.feishu.buffer_snapshot('message') or { panic('missing') }
	packet := transport.WorkerWebSocketUpstreamCommand{
		type_:       'session.bind'
		provider:    'feishu'
		instance:    'main'
		stream_id:   'stream'
		target:      'message'
		target_type: 'message_id'
		metadata:    {
			'stream_generation': old.generation
		}
	}
	mut handler := FeishuCommandHandler.new(mut host)
	mut receipt := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut receipt)
	assert handled
	assert receipt.status == 'bound'
	assert receipt.stream_generation != ''
	assert receipt.stream_generation != old.generation
	assert host.app.providers.feishu.admit_wire_stream_command('message', 'stream', 'main', receipt.stream_generation) != none
	assert host.app.providers.feishu.admit_wire_stream_command('message', 'stream', 'main', old.generation) == none
	assert host.notified == 1
}

fn (mut h StreamAdmissionHost) codex_release_feishu_targets(released feishu.WireStreamRelease) {
	h.app.codex_release_feishu_targets(released)
}
