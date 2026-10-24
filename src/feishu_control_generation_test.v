module main

import codex
import command
import config
import executor as execmod
import feishu
import json2 as json
import net.websocket
import upstream
import upstream.transport

fn control_generation_app() &App {
	mut app := &App{
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
	app.providers.feishu.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'keep')
	app.codex_add_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message' })
	return app
}

fn control_generation_packet(kind string, generation string, target string) transport.WorkerWebSocketUpstreamCommand {
	return transport.WorkerWebSocketUpstreamCommand{
		type_:       kind
		provider:    'feishu'
		instance:    'main'
		stream_id:   'stream'
		target:      target
		target_type: if kind == 'provider.message.send' { 'chat_id' } else { 'message_id' }
		text:        'late'
		metadata:    {
			'stream_generation': generation
		}
	}
}

fn control_generation_execute(mut app App, packet transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
	assert handled
	return activity
}

fn test_control_old_or_missing_clear_cannot_retire_identical_replacement() {
	for target in ['', 'message'] {
		for missing in [false, true] {
			mut app := control_generation_app()
			generation := app.providers.feishu.buffers['message'].generation
			packet := control_generation_packet('session.clear', if missing {
				''
			} else {
				generation
			}, target)
			app.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'replacement')
			assert control_generation_execute(mut app, packet).error == 'feishu_stream_command_retired'
			assert app.providers.feishu.buffers['message'].content == 'replacement'
			assert app.codex_find_stream_targets('stream').len == 1
			assert app.providers.feishu.http_test_calls == 0
		}
	}
}

fn test_control_old_bind_cannot_steal_replacement_or_recreate_withdrawn_target() {
	for clear in [false, true] {
		mut app := control_generation_app()
		packet := control_generation_packet('session.bind', app.providers.feishu.buffers['message'].generation, 'message')
		app.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'replacement')
		if clear { app.providers.feishu.clear_buffer('message') }
		assert control_generation_execute(mut app, packet).error == 'feishu_stream_command_retired'
		if clear {
			assert app.providers.feishu.buffers.len == 0
		} else {
			assert app.providers.feishu.buffers['message'].content == 'replacement'
		}
	}
}

fn test_control_current_bind_rotates_and_current_clear_releases_the_new_generation() {
	mut app := control_generation_app()
	old := app.providers.feishu.buffers['message'].generation
	bound := control_generation_execute(mut app, control_generation_packet('session.bind', old, 'message'))
	assert bound.status == 'bound'
	assert bound.stream_generation != '' && bound.stream_generation != old
	assert control_generation_execute(mut app, control_generation_packet('session.clear', old, '')).error != ''
	assert control_generation_execute(mut app, control_generation_packet('session.clear', bound.stream_generation, '')).status == 'cleared'
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets('stream').len == 0
}

fn test_control_clear_preserves_other_generations_and_platforms_across_registries() {
	mut app := control_generation_app()
	generation := app.providers.feishu.buffers['message'].generation
	app.providers.feishu.register_stream_buffer('other', 'stream', 'main', '', '', 'other')
	app.codex_add_stream_target('secondary', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message' })
	app.codex_add_stream_target('secondary', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'other' })
	app.codex_add_stream_target('main', 'stream', codex.CodexTarget{ platform: 'other', message_id: 'message' })
	assert control_generation_execute(mut app, control_generation_packet('session.clear', generation, '')).status == 'cleared'
	assert app.providers.feishu.buffers.len == 1
	assert app.providers.feishu.buffers['other'].content == 'other'
	assert app.codex_stream_targets('main', 'stream').len == 1
	assert app.codex_stream_targets('main', 'stream')[0].platform == 'other'
	assert app.codex_stream_targets('secondary', 'stream').len == 1
	assert app.codex_stream_targets('secondary', 'stream')[0].message_id == 'other'
}

fn test_control_initial_send_stale_generation_is_rejected_before_http() {
	mut app := control_generation_app()
	packet := control_generation_packet('provider.message.send', 'old', 'chat')
	assert control_generation_execute(mut app, packet).error == 'feishu_initial_send_retired'
	assert app.providers.feishu.http_test_calls == 0
	assert app.providers.feishu.buffers['message'].content == 'keep'
}

fn test_control_bridge_initial_send_has_independent_generation_admission() {
	mut app := control_generation_app()
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	state := bridge_authority_test_server(mut app, client)
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeProxyRequest{
			type_:      feishu.bridge_proxy_request_type
			request_id: 'late-initial'
			action:     'send'
			request:    upstream.UpstreamSendRequest{
				provider:    'feishu'
				instance:    'main'
				target:      'chat'
				target_type: 'chat_id'
				text:        'late'
				metadata:    {
					'stream_id':         'stream'
					'stream_generation': 'old'
				}
			}
		}).bytes()
	}, state) or { panic(err) }
	assert app.providers.feishu.http_test_calls == 0
	assert app.providers.feishu.buffers['message'].content == 'keep'
}

fn test_control_bind_clear_prebuilt_packets_linearize_without_refreshed_authority() {
	for _ in 0 .. 24 {
		mut app := control_generation_app()
		generation := app.providers.feishu.buffers['message'].generation
		bind := control_generation_packet('session.bind', generation, 'message')
		clear := control_generation_packet('session.clear', generation, 'message')
		one := spawn control_generation_execute(mut app, bind)
		two := spawn control_generation_execute(mut app, clear)
		a := one.wait()
		b := two.wait()
		assert (a.status == 'bound') != (b.status == 'cleared')
		assert app.providers.feishu.buffers.len == app.codex_find_stream_targets('stream').len
	}
}

fn test_control_clear_mutates_stored_alias_entries_without_replacing_their_runtime() {
	mut app := control_generation_app()
	generation := app.providers.feishu.buffers['message'].generation
	for name in ['default', 'main'] {
		app.providers.codex.instances[name] = codex.ProviderRuntime{
			instance:         name
			active_stream_id: 'foreign'
			stream_map:       {
				'stream': [
					codex.CodexTarget{ platform: 'feishu', message_id: 'message' },
					codex.CodexTarget{ platform: 'other', message_id: 'retain' },
				]
			}
		}
	}
	assert control_generation_execute(mut app, control_generation_packet('session.clear', generation, '')).status == 'cleared'
	for name in ['default', 'main'] {
		rt := app.providers.codex.instances[name] or { panic('lost registry') }
		assert rt.instance == name
		assert rt.active_stream_id == 'foreign'
		assert rt.stream_map['stream'].len == 1
		assert rt.stream_map['stream'][0].message_id == 'retain'
	}
}

fn test_control_clear_cancels_error_only_jobs_but_preserves_retained_alias_owner() {
	for retained in [false, true] {
		mut app := control_generation_app()
		generation := app.providers.feishu.buffers['message'].generation
		if retained {
			app.providers.codex.instances['default'] = codex.ProviderRuntime{
				instance:   'default'
				stream_map: {
					'stream': [codex.CodexTarget{ platform: 'other', message_id: 'keep' }]
				}
			}
		}
		job := app.codex_queue_error_burst(if retained { 'main' } else { 'orphan' }, 'stream', 'old') or { panic('missing job') }
		defer { job.finish() }
		assert control_generation_execute(mut app, control_generation_packet('session.clear', generation, '')).status == 'cleared'
		assert job.run.stopped() == !retained
	}
}

fn test_target_clear_releases_owned_finish_segments_and_preserves_other_target_owners() {
	mut app := control_generation_app()
	generation := app.providers.feishu.buffers['message'].generation
	for target in [
		codex.CodexTarget{ platform: 'feishu', message_id: 'finish-segment', stream_generation: generation, buffer_message_id: 'message' },
		codex.CodexTarget{ platform: 'feishu', message_id: 'peer', stream_generation: generation, buffer_message_id: 'other' },
		codex.CodexTarget{ platform: 'feishu', message_id: 'message', stream_generation: 'foreign', buffer_message_id: 'message' },
	] {
		app.codex_add_stream_target('secondary', 'stream', target)
	}
	assert control_generation_execute(mut app, control_generation_packet('session.clear', generation, 'message')).status == 'cleared'
	targets := app.codex_stream_targets('secondary', 'stream')
	assert targets.len == 2
	assert targets[0].message_id == 'peer'
	assert targets[1].stream_generation == 'foreign'
}

fn test_initial_send_publication_replaces_stale_target_generation_metadata() {
	mut app := control_generation_app()
	app.providers.feishu.clear_buffer('message')
	app.codex_add_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'om_test_1', stream_generation: 'old', buffer_message_id: 'om_test_1' })
	app.codex_add_stream_target('secondary', 'other-stream', codex.CodexTarget{ platform: 'feishu', message_id: 'om_test_1', stream_generation: 'old', buffer_message_id: 'om_test_1' })
	lease := app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	mut packet := control_generation_packet('provider.message.send', lease.generation, 'chat')
	packet.metadata['creation_token'] = lease.token
	receipt := control_generation_execute(mut app, packet)
	assert receipt.status == 'sent'
	assert receipt.stream_generation == lease.generation
	targets := app.codex_find_stream_targets('stream').filter(it.message_id == 'om_test_1')
	assert targets.len == 1
	assert targets[0].stream_generation == lease.generation
	assert targets[0].buffer_message_id == 'om_test_1'
	assert app.codex_stream_targets('secondary', 'other-stream').len == 0
}
