module main

import executor
import codex
import upstream.transport
import worker

struct CodexRuntimeTestDispatchState {
mut:
	dispatch_count int
	last_req       transport.WorkerWebSocketUpstreamDispatchRequest
}

struct CodexRuntimeTestExecutor {
mut:
	state &CodexRuntimeTestDispatchState = unsafe { nil }
}

pub fn (e CodexRuntimeTestExecutor) kind() string {
	return 'vjsx'
}

pub fn (e CodexRuntimeTestExecutor) model() executor.LogicExecutorModel {
	return .embedded
}

pub fn (e CodexRuntimeTestExecutor) provider() string {
	return 'vjsx'
}

pub fn (e CodexRuntimeTestExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'vjsx'
		provider: 'vjsx'
		model:    executor.LogicExecutorModel.embedded.str()
	}
}

pub fn (e CodexRuntimeTestExecutor) warmup(mut app executor.AppFacade) ! {
	_ = e
	_ = app
}

pub fn (e CodexRuntimeTestExecutor) close() {
	_ = e
}

pub fn (e CodexRuntimeTestExecutor) dispatch_http(mut app executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) open_websocket_session(mut app executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) dispatch_stream(mut app executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) dispatch_mcp(mut app executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	_ = app
	_ = req
	return error('not_used')
}

pub fn (e CodexRuntimeTestExecutor) dispatch_websocket_upstream(mut app executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = app
	if !isnil(e.state) {
		mut state := e.state
		state.dispatch_count++
		state.last_req = req
	}
	return transport.WorkerWebSocketUpstreamDispatchResponse{
		mode:     'websocket_upstream'
		event:    'result'
		id:       req.id
		handled:  true
		commands: []transport.WorkerWebSocketUpstreamCommand{}
	}
}

pub fn (e CodexRuntimeTestExecutor) dispatch_websocket_event(mut app executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = app
	_ = frame
	return error('not_used')
}

fn test_codex_encode_request_and_notification() {
	req := codex.encode_request('turn/start', 42, '{"a":1}')
	assert req.contains('"method":"turn/start"')
	assert req.contains('"id":42')
	assert req.contains('"params":')

	notif := codex.encode_notification('initialized', '{}')
	assert notif.contains('"method":"initialized"')
	assert notif.contains('"params":{}')
}

fn test_codex_classify_rpc_variants() {
	// response (has id + result)
	resp := '{"id":1,"result":{"ok":true}}'
	c := codex.classify_rpc(resp)
	assert c.is_response

	// notification (method only)
	notif := '{"method":"thread/started","thread":{"id":"t1"}}'
	n := codex.classify_rpc(notif)
	assert n.is_notification
	assert n.method == 'thread/started'

	// request (method + id)
	req := '{"method":"approve","id":7,"params":{}}'
	r := codex.classify_rpc(req)
	assert r.is_request
	assert r.method == 'approve'
	assert r.id_raw == '7'
}

fn test_codex_extractors() {
	raw := '{"id":123,"method":"mymethod","thread":{"id":"th-1"},"obj":{"a":1}}'
	s := codex.extract_string_field(raw, 'method')
	assert s == 'mymethod'
	idraw := codex.extract_raw_field(raw, 'id')
	assert idraw == '123'
	obj := codex.extract_raw_field(raw, 'obj')
	assert obj.contains('{')
}

fn test_admin_codex_snapshot_reflects_runtime() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled:            true
					url:                'https://codex.example'
					model:              'gpt-test'
					effort:             'low'
					cwd:                '/tmp'
					approval_policy:    'auto'
					sandbox:            'read-only'
					flush_interval_ms:  1500
					reconnect_delay_ms: 4000
				}
			}
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
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{}
			}
		}
	}
	id1 := app.codex_next_rpc_id('main')
	id2 := app.codex_next_rpc_id('main')
	assert id2 == id1 + 1
}

fn test_websocket_upstream_reconnect_delay_default_and_override() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{}
			}
		}
	}
	// default when unset
	assert app.websocket_upstream_provider_reconnect_delay_ms(websocket_upstream_provider_codex,
		'main') == 3000

	app.providers.codex.runtime.reconnect_delay_ms = 5500
	assert app.websocket_upstream_provider_reconnect_delay_ms(websocket_upstream_provider_codex,
		'main') == 5500
}

fn test_codex_get_active_stream_id_and_set() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{}
			}
		}
	}
	app.providers.codex.runtime.active_stream_id = 'stream-1'
	assert app.codex_get_active_stream_id_for_instance('main') == 'stream-1'
}

fn test_codex_runtime_bind_and_clear_thread_binding() {
	mut rt := codex.ProviderRuntime{
		thread_stream_map: map[string]string{}
		stream_map:        map[string][]codex.CodexTarget{}
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

fn test_codex_notification_active_does_not_schedule_read_fallback() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					thread_stream_map:   map[string]string{}
					stream_map:          map[string][]codex.CodexTarget{}
					pending_rpcs:        map[int]codex.PendingRpc{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					read_fallbacks:      map[string]codex.ReadFallback{}
				}
			}
		}
	}
	app.codex_bind_stream_to_thread('main', 'thread_watchdog_001', 'stream_watchdog_001')
	app.codex_handle_notification('main', 'thread/status/changed',
		'{"method":"thread/status/changed","params":{"threadId":"thread_watchdog_001","status":{"type":"active","activeFlags":[]}}}')
	_, ok := app.codex_read_fallback('main', 'stream_watchdog_001')
	assert !ok
}

fn test_codex_notification_delta_clears_read_fallback() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					thread_stream_map:   map[string]string{}
					stream_map:          map[string][]codex.CodexTarget{}
					pending_rpcs:        map[int]codex.PendingRpc{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					read_fallbacks:      map[string]codex.ReadFallback{}
				}
			}
		}
	}
	app.codex_bind_stream_to_thread('main', 'thread_watchdog_002', 'stream_watchdog_002')
	_, _ = app.codex_schedule_read_fallback('main', 'stream_watchdog_002', 'thread_watchdog_002')
	app.codex_handle_notification('main', 'item/agentMessage/delta',
		'{"method":"item/agentMessage/delta","params":{"threadId":"thread_watchdog_002","delta":"hello"}}')
	_, ok := app.codex_read_fallback('main', 'stream_watchdog_002')
	assert !ok
}

fn test_codex_notification_reasoning_delta_clears_read_fallback() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					thread_stream_map:   map[string]string{}
					stream_map:          map[string][]codex.CodexTarget{}
					pending_rpcs:        map[int]codex.PendingRpc{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					read_fallbacks:      map[string]codex.ReadFallback{}
				}
			}
		}
	}
	app.codex_bind_stream_to_thread('main', 'thread_watchdog_reasoning_001',
		'stream_watchdog_reasoning_001')
	_, _ = app.codex_schedule_read_fallback('main', 'stream_watchdog_reasoning_001',
		'thread_watchdog_reasoning_001')
	app.codex_handle_notification('main', 'item/reasoning/textDelta',
		'{"method":"item/reasoning/textDelta","params":{"threadId":"thread_watchdog_reasoning_001","itemId":"item_reasoning_001","delta":"thinking"}}')
	_, ok := app.codex_read_fallback('main', 'stream_watchdog_reasoning_001')
	assert !ok
}

fn test_codex_turn_start_response_does_not_schedule_read_fallback() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					thread_stream_map:   map[string]string{}
					stream_map:          map[string][]codex.CodexTarget{}
					pending_rpcs:        map[int]codex.PendingRpc{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					read_fallbacks:      map[string]codex.ReadFallback{}
				}
			}
		}
	}
	app.codex_remember_pending_rpc('main', 7, codex.PendingRpc{
		instance:  'main'
		method:    'turn/start'
		stream_id: 'stream_turn_start_001'
	})
	app.codex_handle_response('main', codex.RpcClassification{
		id_raw:      '7'
		is_response: true
	}, '{"id":7,"result":{"turn":{"id":"turn_001","status":"inProgress","error":null}}}')
	_, ok := app.codex_read_fallback('main', 'stream_turn_start_001')
	assert !ok
}

fn test_codex_runtime_add_remove_and_clear_stream_targets() {
	mut rt := codex.ProviderRuntime{
		thread_stream_map: map[string]string{}
		stream_map:        map[string][]codex.CodexTarget{}
		active_stream_id:  'stream_001'
	}
	rt.add_stream_target('stream_001', codex.CodexTarget{
		platform:   'feishu'
		message_id: 'om_001'
	})
	rt.add_stream_target('stream_001', codex.CodexTarget{
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

fn test_codex_find_stream_targets_scans_across_instances() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime:   codex.ProviderRuntime{
					instance:            'main'
					thread_stream_map:   map[string]string{}
					stream_map:          {
						'codex:stream_001': [
							codex.CodexTarget{
								platform:   'feishu'
								message_id: 'om_main_001'
							},
						]
					}
					pending_rpcs:        map[int]codex.PendingRpc{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					read_fallbacks:      map[string]codex.ReadFallback{}
				}
				instances: {
					'local4501': codex.ProviderRuntime{
						instance:            'local4501'
						active_stream_id:    'codex:stream_001'
						thread_stream_map:   {
							'thread_local_001': 'codex:stream_001'
						}
						stream_map:          map[string][]codex.CodexTarget{}
						pending_rpcs:        map[int]codex.PendingRpc{}
						err_bursts:          map[string][]string{}
						err_pending_flushes: map[string]bool{}
						read_fallbacks:      map[string]codex.ReadFallback{}
					}
				}
			}
		}
	}
	assert app.codex_resolve_instance_for_stream('codex:stream_001') == 'local4501'
	targets := app.codex_find_stream_targets('codex:stream_001')
	assert targets.len == 1
	assert targets[0].platform == 'feishu'
	assert targets[0].message_id == 'om_main_001'
}

fn test_codex_dispatch_rpc_response_uses_logic_executor_without_worker_sockets() {
	mut state := &CodexRuntimeTestDispatchState{}
	mut app := App{
		engines: EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: CodexRuntimeTestExecutor{
					state: state
				}
			}
		}
	}
	app.dispatch_codex_rpc_response('main', codex.PendingRpc{
		instance:   'main'
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
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: CodexRuntimeTestExecutor{
					state: state
				}
			}
		}
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					active_stream_id: 'codex:task_002'
				}
			}
		}
	}
	app.codex_handle_notification('main', 'item/agentMessage/delta',
		'{"method":"item/agentMessage/delta","params":{"delta":"hello"}}')
	assert state.dispatch_count == 1
	assert state.last_req.provider == 'codex'
	assert state.last_req.event_type == 'codex.notification'
	assert state.last_req.trace_id == 'codex:task_002'
	assert state.last_req.payload.contains('"delta":"hello"')
}

fn test_codex_notification_prefers_thread_bound_stream_over_active_stream() {
	mut state := &CodexRuntimeTestDispatchState{}
	mut app := App{
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: CodexRuntimeTestExecutor{
					state: state
				}
			}
		}
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					active_stream_id:    'codex:wrong_active'
					thread_stream_map:   {
						'thread_live_001': 'codex:thread_bound_001'
					}
					stream_map:          map[string][]codex.CodexTarget{}
					pending_rpcs:        map[int]codex.PendingRpc{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					read_fallbacks:      map[string]codex.ReadFallback{}
				}
			}
		}
	}
	app.codex_handle_notification('main', 'thread/realtime/itemAdded',
		'{"method":"thread/realtime/itemAdded","params":{"threadId":"thread_live_001","item":{"id":"item_live_001","type":"reasoning"}}}')
	assert state.dispatch_count == 1
	assert state.last_req.event_type == 'codex.notification'
	assert state.last_req.trace_id == 'codex:thread_bound_001'
	assert state.last_req.payload.contains('"threadId":"thread_live_001"')
}

fn test_codex_server_request_uses_logic_executor_without_worker_sockets() {
	mut state := &CodexRuntimeTestDispatchState{}
	mut app := App{
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: CodexRuntimeTestExecutor{
					state: state
				}
			}
		}
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					active_stream_id: 'codex:task_approval_001'
				}
			}
		}
	}
	app.codex_handle_server_request('main', codex.RpcClassification{
		is_request: true
		method:     'item/commandExecution/requestApproval'
		id_raw:     '991'
	},
		'{"method":"item/commandExecution/requestApproval","id":991,"params":{"threadId":"thread_approval_001","turnId":"turn_approval_001","itemId":"item_approval_001","command":"rm foo"}}')
	assert state.dispatch_count == 1
	assert state.last_req.provider == 'codex'
	assert state.last_req.event_type == 'codex.server_request'
	assert state.last_req.trace_id == 'codex:task_approval_001'
	assert state.last_req.payload.contains('"command":"rm foo"')
}
