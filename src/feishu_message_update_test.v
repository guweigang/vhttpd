module main

import codex
import command
import config
import executor as execmod
import feishu
import upstream
import upstream.transport

@[heap]
struct MessageUpdateHost {
	App
mut:
	entered          chan bool = chan bool{cap: 2}
	release          chan bool = chan bool{cap: 2}
	calls            int
	notices          int
	fail             bool
	captured_content string
	bad_result       bool
}

fn (mut h MessageUpdateHost) websocket_upstream_update(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	h.captured_content = req.metadata['feishu_update_captured_content'] or { 'missing' }
	h.calls++
	h.entered <- true
	_ = <-h.release
	if h.fail { return error('fixture_http_failure') }
	return upstream.UpstreamUpdateResult{ ok: !h.bad_result, provider: 'feishu', instance: req.instance, message_id: req.target }
}

fn (mut h MessageUpdateHost) dispatch_feishu_message_updated(_stream string, _message string) {
	h.notices++
}

fn message_update_fixture() &MessageUpdateHost {
	mut h := &MessageUpdateHost{}
	h.providers.feishu.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'queued')
	h.codex_rebind_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message', buffer_message_id: 'message', stream_generation: h.providers.feishu.buffers['message'].generation })
	return h
}

fn message_update_packet(generation string, target string) transport.WorkerWebSocketUpstreamCommand {
	return transport.WorkerWebSocketUpstreamCommand{
		type_:        'provider.message.update'
		provider:     'feishu'
		instance:     'main'
		stream_id:    'stream'
		target:       target
		target_type:  'message_id'
		message_type: 'interactive'
		content:      '{"elements":[]}'
		metadata:     {
			'stream_generation': generation
		}
	}
}

fn message_update_execute(mut h MessageUpdateHost, packet transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut h)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
	assert handled
	return activity
}

fn test_plain_update_late_packet_rejects_before_http_and_preserves_replacement() {
	for clear in [false, true] {
		mut h := message_update_fixture()
		packet := message_update_packet(h.providers.feishu.buffers['message'].generation, 'message')
		h.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'replacement')
		if clear { h.providers.feishu.clear_stream_buffers('stream') }
		assert message_update_execute(mut h, packet).error == 'feishu_message_update_retired'
		assert h.calls == 0 && h.notices == 0
		if !clear {
			assert h.providers.feishu.buffers['message'].content == 'replacement'
		}
	}
}

fn test_plain_update_missing_wrong_scope_and_message_id_alone_cannot_send_or_clear() {
	mut h := message_update_fixture()
	gen := h.providers.feishu.buffers['message'].generation
	for packet in [message_update_packet('', 'message'),
		transport.WorkerWebSocketUpstreamCommand{ ...message_update_packet(gen, 'message'), stream_id: '' },
		transport.WorkerWebSocketUpstreamCommand{ ...message_update_packet(gen, 'message'), instance: 'other' },
		transport.WorkerWebSocketUpstreamCommand{
			...message_update_packet(gen, 'message')
			metadata: {
				'stream_generation': gen
				'stream_id':         'other'
			}
		}] {
		assert message_update_execute(mut h, packet).status == 'error'
		assert h.providers.feishu.buffers['message'].content == 'queued'
	}
	assert h.calls == 0
}

fn test_plain_update_inflight_rebind_clear_and_recreation_reject_completion_notification() {
	for mode in ['rebind', 'clear', 'recreate'] {
		mut h := message_update_fixture()
		packet := message_update_packet(h.providers.feishu.buffers['message'].generation, 'message')
		job := spawn message_update_execute(mut h, packet)
		_ = <-h.entered
		assert h.providers.feishu.buffers['message'].generation == packet.metadata['stream_generation']
		if mode != 'rebind' { h.providers.feishu.clear_stream_buffers('stream') }
		if mode == 'rebind' {
			bound := message_update_execute(mut h, transport.WorkerWebSocketUpstreamCommand{
				type_:       'session.bind'
				provider:    'feishu'
				instance:    'main'
				stream_id:   'replacement'
				target:      'message'
				target_type: 'message_id'
				metadata:    {
					'stream_generation': packet.metadata['stream_generation']
				}
			})
			assert bound.status == 'bound'
			h.providers.feishu.append_buffer_patch('message', 'main', 'new generation')
		} else if mode != 'clear' {
			h.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'new generation')
		}
		h.release <- true
		result := job.wait()
		assert result.error == 'feishu_message_update_retired'
		assert h.captured_content == 'queued'
		assert h.notices == 0
		if mode != 'clear' {
			assert h.providers.feishu.buffers['message'].content == 'new generation'
		}
		if mode == 'rebind' {
			assert h.codex_find_stream_targets('replacement')[0].stream_generation == h.providers.feishu.buffers['message'].generation
		}
	}
}

fn test_plain_update_success_keeps_owner_for_subsequent_updates_and_blocks_stream_revival() {
	mut h := message_update_fixture()
	gen := h.providers.feishu.buffers['message'].generation
	for _ in 0 .. 2 {
		job := spawn message_update_execute(mut h, message_update_packet(gen, 'message'))
		_ = <-h.entered
		h.release <- true
		result := job.wait()
		assert result.status == 'updated' && result.stream_generation == gen
	}
	assert h.calls == 2 && h.notices == 2
	assert h.providers.feishu.admit_wire_stream_command('message', 'stream', 'main', gen) == none
	assert h.providers.feishu.buffers['message'].generation == gen
}

fn test_plain_update_http_error_and_negative_result_release_only_the_original_operation() {
	for bad in [false, true] {
		mut h := message_update_fixture()
		h.fail = !bad
		h.bad_result = bad
		gen := h.providers.feishu.buffers['message'].generation
		job := spawn message_update_execute(mut h, message_update_packet(gen, 'message'))
		_ = <-h.entered
		h.release <- true
		assert job.wait().status == 'error'
		assert h.notices == 0
		assert h.providers.feishu.buffers['message'].content == 'queued'
		h.fail = false
		h.bad_result = false
		retry := spawn message_update_execute(mut h, message_update_packet(gen, 'message'))
		_ = <-h.entered
		h.release <- true
		assert retry.wait().status == 'updated'
	}
}

fn test_plain_update_queued_old_request_cannot_enter_rebound_buffer() {
	mut h := message_update_fixture()
	packet := message_update_packet(h.providers.feishu.buffers['message'].generation, 'message')
	first := spawn message_update_execute(mut h, packet)
	_ = <-h.entered
	second := spawn message_update_execute(mut h, packet)
	h.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'keep')
	h.release <- true
	assert first.wait().status == 'error'
	assert second.wait().status == 'error'
	assert h.calls == 1 && h.notices == 0
	assert h.providers.feishu.buffers['message'].content == 'keep'
}

fn test_plain_generic_update_rejects_raw_codex_and_implicit_feishu_fallback_before_io() {
	mut h := message_update_fixture()
	// A regressed handler can return without hanging on the HTTP barrier; the
	// status and zero-call assertions below must detect that regression.
	h.release <- true
	mut handler := GenericUpstreamCommandHandler.new(mut h)
	for cmd in [
		transport.WorkerWebSocketUpstreamCommand{ type_: 'provider.message.update', provider: 'codex', instance: 'replacement', text: '{"method":"turn/start"}' },
		transport.WorkerWebSocketUpstreamCommand{ type_: 'codex.message.update', provider: 'codex', instance: 'replacement', text: '{"method":"turn/start"}' },
		transport.WorkerWebSocketUpstreamCommand{ event: 'update', stream_id: 'stream', target: 'message', message_type: 'interactive', content: '{"elements":[]}' },
	] {
		mut activity := execmod.WebSocketUpstreamCommandActivity{}
		handled, err := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
		assert handled
		assert err == if cmd.provider == '' {
			'provider_message_update_provider_required'
		} else {
			'codex_message_update_unsupported_use_rpc'
		}
		assert activity.status == 'error'
		assert h.calls == 0
	}
}

fn test_plain_implicit_feishu_update_cannot_enter_provider_via_command_executor() {
	mut app := &App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled:        true
				open_base_url:  'https://open.feishu.test/open-apis'
				apps:           {
					'main': config.FeishuAppConfig{ app_id: 'fixture', app_secret: 'fixture' }
				}
				http_test_stub: true
			}
		}
	}
	app.providers.feishu.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'keep')
	cmd := transport.WorkerWebSocketUpstreamCommand{ event: 'update', target: 'message', message_type: 'interactive', content: '{"elements":[]}' }
	activities, err := app.execute_command_envelopes_with_snapshots('implicit-update', DispatchContext{}, [cmd])
	assert err == 'provider_message_update_provider_required'
	assert activities.len == 1 && activities[0].status == 'error'
	assert app.providers.feishu.http_test_calls == 0
	assert app.providers.feishu.buffers['message'].content == 'keep'
}
