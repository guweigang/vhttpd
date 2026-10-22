module main

import codex
import command
import executor
import upstream.transport

fn test_codex_targetless_active_stream_release_is_independent_and_idempotent() {
	mut rt := codex.ProviderRuntime{
		active_stream_id: 'targetless'
		stream_map:       {
			'other': [codex.CodexTarget{ platform: 'feishu', message_id: 'keep' }]
		}
	}
	assert !rt.clear_stream_targets('')
	assert !rt.clear_stream_targets('missing')
	assert rt.current_stream_id() == 'targetless'
	assert rt.clear_stream_targets('targetless')
	assert rt.current_stream_id() == ''
	assert !rt.clear_stream_targets('targetless')
	assert rt.stream_targets('other')[0].message_id == 'keep'
	// A subsequent notification with a previously unseen thread cannot recover
	// the retired stream through the active-stream fallback.
	assert rt.repair_thread_stream_binding('new-thread') == ''
}

fn test_codex_release_after_last_target_removed_keeps_unrelated_active_stream() {
	for active in ['retired', 'other'] {
		mut rt := codex.ProviderRuntime{ active_stream_id: active }
		rt.add_stream_target('retired', codex.CodexTarget{ platform: 'feishu', message_id: 'last' })
		assert rt.remove_stream_target('retired', 'feishu', 'last')
		assert 'retired' !in rt.stream_map
		assert rt.clear_stream_targets('retired') == (active == 'retired')
		assert rt.current_stream_id() == if active == 'retired' { '' } else { 'other' }
	}
}

fn test_codex_session_clear_without_message_targets_reports_release_for_named_instance() {
	mut app := &App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime:   codex.ProviderRuntime{ instance: 'main', active_stream_id: 'keep-main' }
				instances: {
					'secondary': codex.ProviderRuntime{ instance: 'secondary', active_stream_id: 'retired' }
				}
			}
		}
	}
	handler := CodexCommandHandler.new(mut app)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:     'session.clear'
		provider:  'codex'
		instance:  'secondary'
		stream_id: 'retired'
	}
	normalized := command.NormalizedCommand.from_worker_command(cmd)
	mut activity := executor.WebSocketUpstreamCommandActivity{}
	handled, failure := handler.execute(cmd, normalized, mut activity)
	assert handled
	assert failure == ''
	assert activity.status == 'cleared'
	assert app.codex_get_active_stream_id_for_instance('secondary') == ''
	assert app.codex_get_active_stream_id_for_instance('main') == 'keep-main'
	assert app.codex_repair_thread_stream_binding('secondary', 'new-thread') == ''
	mut repeated := executor.WebSocketUpstreamCommandActivity{}
	again, _ := handler.execute(cmd, normalized, mut repeated)
	assert !again
}

fn test_feishu_session_clear_releases_targetless_codex_routes_across_instances() {
	mut app := &App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime:   codex.ProviderRuntime{ instance: 'main', active_stream_id: 'retired' }
				instances: {
					'secondary': codex.ProviderRuntime{ instance: 'secondary', active_stream_id: 'retired' }
					'other':     codex.ProviderRuntime{ instance: 'other', active_stream_id: 'keep-other' }
				}
			}
		}
	}
	claim := app.providers.feishu.begin_wire_initial_send('retired', '', 'route-owner') or { panic('missing claim') }
	defer { app.providers.feishu.finish_initial_send(claim) }
	handler := FeishuCommandHandler.new(mut app)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		metadata:  {
			'stream_generation': 'route-owner'
		}
		type_:     'session.clear'
		provider:  'feishu'
		stream_id: 'retired'
	}
	mut activity := executor.WebSocketUpstreamCommandActivity{}
	handled, failure := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert handled
	assert failure == ''
	assert activity.status == 'cleared'
	assert app.codex_get_active_stream_id_for_instance('main') == ''
	assert app.codex_get_active_stream_id_for_instance('secondary') == ''
	assert app.codex_get_active_stream_id_for_instance('other') == 'keep-other'
	assert app.providers.feishu.buffers.len == 0
}
