module main

import transport
import codex
import ws

fn test_websocket_upstream_reconnect_and_admin_helpers() {
	mut app := App{
		codex: codex.CodexState{
			runtime: codex.ProviderRuntime{}
		}
	}

	// reconnect delay default
	assert app.websocket_upstream_provider_reconnect_delay_ms(websocket_upstream_provider_codex,
		'main') == 3000

	app.codex.runtime.reconnect_delay_ms = 7200
	assert app.websocket_upstream_provider_reconnect_delay_ms(websocket_upstream_provider_codex,
		'main') == 7200

	// admin snapshot includes config mapping
	app.codex.runtime.enabled = true
	app.codex.runtime.url = 'https://example'
	app.codex.runtime.model = 'm'
	snap := app.admin_codex_snapshot()
	assert snap.enabled
	assert snap.config.url == 'https://example'
	assert snap.config.model == 'm'
}

fn test_upstream_runtime_context_tracks_registry_metrics_and_snapshot() {
	mut app := App{
		ws_hub: ws.HubState{
			upstream_sessions: map[string]ws.UpstreamRuntimeSession{}
		}
	}
	plan := transport.WorkerUpstreamPlanFrame{
		name:               'mock_provider'
		transport:          'http'
		codec:              'json'
		mapper:             'openai_chat'
		output_stream_type: 'text'
		fixture_path:       '/tmp/mock-fixture.jsonl'
	}

	app.upstream_runtime_register(plan, 'post', '/v1/chat/completions?debug=1', 'req_up_1',
		'trace_up_1')
	assert app.ws_hub.stat_upstream_plans_total == 1

	snapshot := app.admin_upstreams_snapshot(true, 10, 0, 'external_upstream', 'mock_provider')
	assert snapshot.active_count == 1
	assert snapshot.returned_count == 1
	assert snapshot.sessions[0].id == 'req_up_1'
	assert snapshot.sessions[0].method == 'POST'
	assert snapshot.sessions[0].path == '/v1/chat/completions'
	assert snapshot.sessions[0].source == 'fixture'

	app.upstream_runtime_note_error()
	assert app.ws_hub.stat_upstream_plan_errors_total == 1

	app.upstream_runtime_unregister('req_up_1')
	assert app.admin_upstreams_snapshot(false, 10, 0, '', '').active_count == 0
}
