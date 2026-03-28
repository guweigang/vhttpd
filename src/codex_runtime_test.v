module main

struct CodexRuntimeTestDispatchState {
mut:
	dispatch_count int
	last_req       WorkerWebSocketUpstreamDispatchRequest
}

struct CodexRuntimeTestExecutor {
mut:
	state &CodexRuntimeTestDispatchState = unsafe { nil }
}

pub fn (e CodexRuntimeTestExecutor) kind() string {
	return 'vjsx'
}

pub fn (e CodexRuntimeTestExecutor) provider() string {
	return 'vjsx'
}

pub fn (e CodexRuntimeTestExecutor) dispatch_http(mut app App, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) open_websocket_session(mut app App, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) dispatch_stream(mut app App, req StreamDispatchRequest) !StreamDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) dispatch_mcp(mut app App, req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) dispatch_websocket_upstream(mut app App, req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	_ = app
	if !isnil(e.state) {
		mut state := e.state
		state.dispatch_count++
		state.last_req = req
	}
	return WorkerWebSocketUpstreamDispatchResponse{
		mode:     'websocket_upstream'
		event:    'result'
		id:       req.id
		handled:  true
		commands: []WorkerWebSocketUpstreamCommand{}
	}
}

pub fn (e CodexRuntimeTestExecutor) dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	_ = app
	_ = frame
	return error('not_used')
}

fn test_codex_encode_request_and_notification() {
    req := codex_encode_request('turn/start', 42, '{"a":1}')
    assert req.contains('"method":"turn/start"')
    assert req.contains('"id":42')
    assert req.contains('"params":')

    notif := codex_encode_notification('initialized', '{}')
    assert notif.contains('"method":"initialized"')
    assert notif.contains('"params":{}')
}

fn test_codex_classify_rpc_variants() {
    // response (has id + result)
    resp := '{"id":1,"result":{"ok":true}}'
    c := codex_classify_rpc(resp)
    assert c.is_response

    // notification (method only)
    notif := '{"method":"thread/started","thread":{"id":"t1"}}'
    n := codex_classify_rpc(notif)
    assert n.is_notification
    assert n.method == 'thread/started'

    // request (method + id)
    req := '{"method":"approve","id":7,"params":{}}'
    r := codex_classify_rpc(req)
    assert r.is_request
    assert r.method == 'approve'
    assert r.id_raw == '7'
}

fn test_codex_extractors() {
    raw := '{"id":123,"method":"mymethod","thread":{"id":"th-1"},"obj":{"a":1}}'
    s := codex_extract_string_field(raw, 'method')
    assert s == 'mymethod'
    idraw := codex_extract_raw_field(raw, 'id')
    assert idraw == '123'
    obj := codex_extract_raw_field(raw, 'obj')
    assert obj.contains('{')
}

fn test_admin_codex_snapshot_reflects_runtime() {
    mut app := App{
        codex_runtime: CodexProviderRuntime{
            enabled: true
            url: 'https://codex.example'
            model: 'gpt-test'
            effort: 'low'
            cwd: '/tmp'
            approval_policy: 'auto'
            sandbox: 'read-only'
            flush_interval_ms: 1500
            reconnect_delay_ms: 4000
        }
    }
    snap := app.admin_codex_snapshot()
    assert snap.enabled
    assert snap.config.url == 'https://codex.example'
    assert snap.config.model == 'gpt-test'
    assert snap.config.effort == 'low'
    assert snap.config.flush_interval == 1500
}

fn test_codex_next_rpc_id_increment() {
    mut app := App{ codex_runtime: CodexProviderRuntime{} }
    id1 := app.codex_next_rpc_id()
    id2 := app.codex_next_rpc_id()
    assert id2 == id1 + 1
}

fn test_websocket_upstream_reconnect_delay_default_and_override() {
    mut app := App{ codex_runtime: CodexProviderRuntime{} }
    // default when unset
    assert websocket_upstream_provider_reconnect_delay_ms(&app, websocket_upstream_provider_codex, 'main') == 3000

    app.codex_runtime.reconnect_delay_ms = 5500
    assert websocket_upstream_provider_reconnect_delay_ms(&app, websocket_upstream_provider_codex, 'main') == 5500
}

fn test_codex_get_active_stream_id_and_set() {
    mut app := App{ codex_runtime: CodexProviderRuntime{} }
    app.codex_runtime.active_stream_id = 'stream-1'
    assert app.codex_get_active_stream_id() == 'stream-1'
}

fn test_codex_runtime_bind_and_clear_thread_binding() {
	mut rt := CodexProviderRuntime{
		thread_stream_map: map[string]string{}
		stream_map:        map[string][]CodexTarget{}
	}
	thread_id := rt.bind_stream_to_thread('thread_001', 'stream_001')
	assert thread_id == 'thread_001'
	assert rt.thread_id == 'thread_001'
	assert rt.thread_stream_map['thread_001'] == 'stream_001'

	cleared := rt.clear_thread_binding('thread_001')
	assert cleared == true
	assert rt.thread_id == ''
	assert 'thread_001' !in rt.thread_stream_map
}

fn test_codex_runtime_add_remove_and_clear_stream_targets() {
	mut rt := CodexProviderRuntime{
		thread_stream_map: map[string]string{}
		stream_map:        map[string][]CodexTarget{}
		active_stream_id:  'stream_001'
	}
	rt.add_stream_target('stream_001', CodexTarget{
		platform:   'feishu'
		message_id: 'om_001'
	})
	rt.add_stream_target('stream_001', CodexTarget{
		platform:   'discord'
		message_id: 'msg_002'
	})
	assert rt.stream_map['stream_001'].len == 2

	removed := rt.remove_stream_target('stream_001', 'feishu', 'om_001')
	assert removed == true
	assert rt.stream_map['stream_001'].len == 1
	assert rt.stream_map['stream_001'][0].platform == 'discord'

	cleared := rt.clear_stream_targets('stream_001')
	assert cleared == true
	assert 'stream_001' !in rt.stream_map
	assert rt.active_stream_id == ''
}

fn test_codex_dispatch_rpc_response_uses_logic_executor_without_worker_sockets() {
	mut state := &CodexRuntimeTestDispatchState{}
	mut app := App{
		logic_executor: CodexRuntimeTestExecutor{
			state: state
		}
	}
	app.dispatch_codex_rpc_response(CodexPendingRpc{
		method:     'thread/start'
		stream_id:  'codex:task_001'
		message_id: 'om_test_001'
	}, '{"threadId":"thread_001"}', false, '{"id":1,"result":{"threadId":"thread_001"}}')
	assert state.dispatch_count == 1
	assert state.last_req.provider == 'codex'
	assert state.last_req.event_type == 'codex.rpc.response'
	assert state.last_req.trace_id == 'codex:task_001'
	assert state.last_req.target == 'codex:task_001'
}

fn test_codex_notification_uses_logic_executor_without_worker_sockets() {
	mut state := &CodexRuntimeTestDispatchState{}
	mut app := App{
		logic_executor: CodexRuntimeTestExecutor{
			state: state
		}
		codex_runtime: CodexProviderRuntime{
			active_stream_id: 'codex:task_002'
		}
	}
	app.codex_handle_notification('item/agentMessage/delta',
		'{"method":"item/agentMessage/delta","params":{"delta":"hello"}}')
	assert state.dispatch_count == 1
	assert state.last_req.provider == 'codex'
	assert state.last_req.event_type == 'codex.notification'
	assert state.last_req.trace_id == 'codex:task_002'
	assert state.last_req.payload.contains('"delta":"hello"')
}
