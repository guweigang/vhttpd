module main

import codex
import command
import executor
import upstream.transport

fn test_codex_stream_release_retires_all_reverse_routes_and_fallback() {
	mut rt := codex.ProviderRuntime{
		thread_id:         'thread-a'
		active_stream_id:  'retired'
		thread_stream_map: {
			'thread-a': 'retired'
			'thread-b': 'retired'
			'keep':     'other'
		}
	}
	rt.schedule_read_fallback('retired', 'thread-a')
	rt.schedule_read_fallback('other', 'keep')
	assert rt.clear_stream_targets('retired')
	assert 'thread-a' !in rt.thread_stream_map
	assert 'thread-b' !in rt.thread_stream_map
	assert rt.thread_stream_map['keep'] == 'other'
	_, found := rt.read_fallback('retired')
	assert !found
	_, keep := rt.read_fallback('other')
	assert keep
	assert rt.current_thread_id() == 'thread-a'
	assert rt.repair_thread_stream_binding('thread-a') == ''
	assert !rt.clear_stream_targets('retired')
}

fn test_codex_stream_release_finds_route_without_targets_or_active_reference() {
	mut rt := codex.ProviderRuntime{
		active_stream_id:  'other'
		thread_stream_map: {
			'retired-thread': 'retired'
			'rebound-thread': 'other'
		}
	}
	assert rt.clear_stream_targets('retired')
	assert 'retired-thread' !in rt.thread_stream_map
	assert rt.thread_stream_map['rebound-thread'] == 'other'
	assert rt.current_stream_id() == 'other'
	assert !rt.clear_stream_targets('retired')
}

fn test_codex_stream_release_finds_fallback_only_and_ignores_empty_id() {
	mut rt := codex.ProviderRuntime{}
	rt.schedule_read_fallback('retired', 'thread')
	assert !rt.clear_stream_targets('')
	assert rt.clear_stream_targets('retired')
	assert rt.read_fallbacks.len == 0
	assert !rt.clear_stream_targets('retired')
}

fn test_codex_session_clear_retires_routes_in_selected_instance() {
	mut app := &App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime:   codex.ProviderRuntime{
					thread_stream_map: {
						'main-thread': 'retired'
					}
				}
				instances: {
					'secondary': codex.ProviderRuntime{
						thread_stream_map: {
							'old-thread': 'retired'
						}
					}
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
	mut activity := executor.WebSocketUpstreamCommandActivity{}
	handled, failure := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert handled
	assert failure == ''
	assert activity.status == 'cleared'
	assert app.codex_repair_thread_stream_binding('secondary', 'old-thread') == ''
	assert app.codex_repair_thread_stream_binding('main', 'main-thread') == 'retired'
}
