module main

fn test_normalized_command_from_worker_command_codex_rpc_send() {
	cmd := WorkerWebSocketUpstreamCommand{
		type_:     'codex.rpc.send'
		stream_id: 'codex:task_001'
		method:    'thread/start'
		params:    '{"cwd":"/tmp/demo"}'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	assert normalized.version == '1'
	assert normalized.kind == 'provider.rpc.call'
	assert normalized.provider == 'codex'
	assert normalized.correlation.stream_id == 'codex:task_001'
	assert normalized.correlation.task_id == 'task_001'
	assert normalized.method == 'thread/start'
}

fn test_normalized_command_from_worker_command_feishu_patch() {
	cmd := WorkerWebSocketUpstreamCommand{
		type_:     'feishu.message.patch'
		target:    'om_xxx'
		stream_id: 'codex:task_002'
		text:      'chunk'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	assert normalized.kind == 'stream.append'
	assert normalized.provider == 'feishu'
	assert normalized.target.id == 'om_xxx'
	assert normalized.correlation.stream_id == 'codex:task_002'
	assert normalized.text == 'chunk'
}

fn test_command_route_from_normalized_provider_message_send_for_feishu() {
	$if no_feishu_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'feishu'
		enabled:          true
		has_handler:      true
		has_runtime:      true
		command_matchers: [CommandMatcher{kind: .prefix, value: 'feishu.message.'}]
		route_kind:       .feishu
		provider:         FeishuProvider{}
		handler:          FeishuCommandHandler.new(mut app)
		runtime:          NoopProviderRuntime{}
	})
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:    'provider.message.send'
		provider: 'feishu'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.feishu
}

fn test_command_route_from_normalized_stream_append_for_feishu() {
	$if no_feishu_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'feishu'
		enabled:          true
		has_handler:      true
		has_runtime:      true
		command_matchers: [CommandMatcher{kind: .prefix, value: 'feishu.message.'}]
		route_kind:       .feishu
		provider:         FeishuProvider{}
		handler:          FeishuCommandHandler.new(mut app)
		runtime:          NoopProviderRuntime{}
	})
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:    'stream.append'
		provider: 'feishu'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.feishu
}

fn test_command_route_from_normalized_stream_fail_for_feishu() {
	$if no_feishu_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'feishu'
		enabled:          true
		has_handler:      true
		has_runtime:      true
		command_matchers: [CommandMatcher{kind: .prefix, value: 'feishu.message.'}]
		route_kind:       .feishu
		provider:         FeishuProvider{}
		handler:          FeishuCommandHandler.new(mut app)
		runtime:          NoopProviderRuntime{}
	})
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:    'stream.fail'
		provider: 'feishu'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.feishu
}

fn test_command_route_from_command_codex_control() {
	$if no_codex_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'codex'
		enabled:          true
		has_handler:      true
		has_runtime:      true
		command_matchers: [CommandMatcher{kind: .prefix, value: 'codex.'}]
		route_kind:       .codex
		provider:         CodexProvider{}
		handler:          CodexCommandHandler.new(mut app)
		runtime:          NoopProviderRuntime{}
	})
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'codex.rpc.send'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.codex
}

fn test_command_route_from_command_feishu_message_prefix() {
	$if no_feishu_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'feishu'
		enabled:          true
		has_handler:      true
		has_runtime:      true
		command_matchers: [CommandMatcher{kind: .prefix, value: 'feishu.message.'}]
		route_kind:       .feishu
		provider:         FeishuProvider{}
		handler:          FeishuCommandHandler.new(mut app)
		runtime:          NoopProviderRuntime{}
	})
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'feishu.message.patch'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.feishu
}

fn test_command_route_from_command_generic_fallback() {
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'discord.message.send'
		event: 'send'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.generic
}

fn test_command_route_from_command_ollama_message_prefix() {
	$if no_ollama_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'ollama'
		enabled:          true
		has_handler:      true
		has_runtime:      true
		command_matchers: [CommandMatcher{kind: .prefix, value: 'ollama.message.'}]
		route_kind:       .ollama
		provider:         OllamaProvider{}
		handler:          GenericUpstreamCommandHandler.new(mut app)
		runtime:          NoopProviderRuntime{}
	})
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'ollama.message.send'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.ollama
}

fn test_provider_spec_command_matchers_are_exposed_in_snapshot() {
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'feishu'
		enabled:          true
		has_handler:      true
		has_runtime:      true
		command_matchers: [CommandMatcher{kind: .prefix, value: 'feishu.message.'}]
		route_kind:       .feishu
		provider:         FeishuProvider{}
		handler:          FeishuCommandHandler.new(mut app)
		runtime:          NoopProviderRuntime{}
	})
	snap := app.admin_provider_specs_snapshot()
	assert snap.len == 1
	assert snap[0].command_matchers.len == 1
	assert snap[0].command_matchers[0] == 'prefix:feishu.message.'
	assert snap[0].route_kind == 'feishu'
}

fn test_command_matcher_exact_kind_matches_exactly() {
	matcher := CommandMatcher{kind: .exact, value: 'codex.rpc.send'}
	assert matcher.matches('codex.rpc.send')
	assert !matcher.matches('codex.rpc.reply')
}

fn test_command_executor_feishu_route_enabled_default_true() {
	$if no_feishu_routes ? {
		return
	}
	assert CommandExecutor.feishu_route_enabled() == true
}

fn test_command_route_from_command_feishu_is_generic_when_disabled() {
	$if !no_feishu_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'feishu.message.patch'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.generic
	assert CommandExecutor.feishu_route_enabled() == false
}

fn test_codex_handler_non_codex_command_not_handled() {
	$if no_codex_routes ? {
		return
	}
	mut app := &App{}
	mut handler := CodexCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'feishu.message.send'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == false
	assert err == ''
}

fn test_command_executor_codex_route_enabled_default_true() {
	$if no_codex_routes ? {
		return
	}
	assert CommandExecutor.codex_route_enabled() == true
}

fn test_command_executor_ollama_route_enabled_default_true() {
	$if no_ollama_routes ? {
		return
	}
	assert CommandExecutor.ollama_route_enabled() == true
}

fn test_command_route_from_command_codex_is_generic_when_disabled() {
	$if !no_codex_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'codex.rpc.send'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.generic
	assert CommandExecutor.codex_route_enabled() == false
}

fn test_command_route_from_command_ollama_is_generic_when_disabled() {
	$if !no_ollama_routes ? {
		return
	}
	mut app := &App{
		providers: ProviderHost{
			specs: map[string]ProviderSpec{}
		}
	}
	mut exec := CommandExecutor.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'ollama.message.send'
		event: 'send'
	}
	assert exec.route_from_specs(cmd) == ProviderRouteKind.generic
	assert CommandExecutor.ollama_route_enabled() == false
}

fn test_feishu_handler_non_feishu_command_not_handled() {
	mut app := &App{}
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'codex.rpc.send'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == false
	assert err == ''
}

fn test_feishu_command_normalize_stream_send_only_applies_to_stream_commands() {
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'feishu.message.send'
	}
	req := WebSocketUpstreamSendRequest{
		provider:     'feishu'
		message_type: 'text'
		text:         'plain'
	}
	normalized_cmd := NormalizedCommand.from_worker_command(cmd)
	normalized := feishu_command_normalize_stream_send(normalized_cmd, req)
	assert normalized.message_type == 'text'
	assert normalized.text == 'plain'
}

fn test_feishu_command_normalize_stream_send_promotes_stream_send_to_interactive() {
	cmd := WorkerWebSocketUpstreamCommand{
		type_:     'feishu.message.send'
		stream_id: 'stream_123'
	}
	req := WebSocketUpstreamSendRequest{
		provider:     'feishu'
		message_type: 'text'
		text:         'stream body'
	}
	normalized_cmd := NormalizedCommand.from_worker_command(cmd)
	normalized := feishu_command_normalize_stream_send(normalized_cmd, req)
	assert normalized.message_type == 'interactive'
	assert normalized.content.contains('stream body')
}

fn test_generic_handler_executes_admin_worker_restart_all_command() {
	mut app := &App{}
	mut handler := GenericUpstreamCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_: 'admin.worker.restart_all'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == true
	assert err == ''
	assert snapshot.status == 'restarted'
	assert snapshot.provider == 'admin'
	assert snapshot.event == 'restart_all'
}

fn test_websocket_upstream_request_from_normalized_uses_default_provider_and_fields() {
	normalized := NormalizedCommand{
		instance:     'main'
		target:       CommandTarget{id: 'oc_123', type_: 'chat_id'}
		message_type: 'text'
		content:      '{"text":"hello"}'
		text:         'hello'
		uuid:         'uuid_123'
		method:       'thread/start'
		params:       '{"cwd":"/tmp/demo"}'
		metadata: {
			'trace_id': 'trace_001'
		}
	}
	req := websocket_upstream_request_from_normalized(normalized, 'discord')
	assert req.provider == 'discord'
	assert req.instance == 'main'
	assert req.target == 'oc_123'
	assert req.target_type == 'chat_id'
	assert req.message_type == 'text'
	assert req.content == '{"text":"hello"}'
	assert req.text == 'hello'
	assert req.uuid == 'uuid_123'
	assert req.method == 'thread/start'
	assert req.params == '{"cwd":"/tmp/demo"}'
	assert req.metadata['trace_id'] == 'trace_001'
}

fn test_websocket_upstream_request_from_normalized_prefers_declared_provider() {
	normalized := NormalizedCommand{
		provider: 'ollama'
	}
	req := websocket_upstream_request_from_normalized(normalized, 'generic')
	assert req.provider == 'ollama'
}

fn test_codex_handler_session_bind_thread_updates_runtime_binding() {
	mut app := &App{
		codex_runtime: CodexProviderRuntime{
			thread_stream_map: map[string]string{}
			stream_map:        map[string][]CodexTarget{}
		}
	}
	mut handler := CodexCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:     'session.bind'
		provider:  'codex'
		stream_id: 'codex:task_001'
		target:    'thread_001'
		target_type: 'thread_id'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == true
	assert err == ''
	assert snapshot.status == 'bound'
	assert app.codex_runtime.thread_id == 'thread_001'
	assert app.codex_runtime.thread_stream_map['thread_001'] == 'codex:task_001'
}

fn test_codex_handler_session_clear_thread_removes_runtime_binding() {
	mut app := &App{
		codex_runtime: CodexProviderRuntime{
			thread_id:         'thread_001'
			thread_stream_map: {
				'thread_001': 'codex:task_001'
			}
			stream_map: map[string][]CodexTarget{}
		}
	}
	mut handler := CodexCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:    'session.clear'
		provider: 'codex'
		target:   'thread_001'
		target_type: 'thread_id'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == true
	assert err == ''
	assert snapshot.status == 'cleared'
	assert app.codex_runtime.thread_id == ''
	assert 'thread_001' !in app.codex_runtime.thread_stream_map
}

fn test_feishu_handler_session_bind_message_registers_stream_target_and_buffer() {
	mut app := &App{
		codex_runtime: CodexProviderRuntime{
			thread_stream_map: map[string]string{}
			stream_map:        map[string][]CodexTarget{}
		}
		feishu_buffers: map[string]FeishuStreamBuffer{}
	}
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:     'session.bind'
		provider:  'feishu'
		instance:  'main'
		stream_id: 'codex:task_002'
		target:    'om_reply_001'
		target_type: 'message_id'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == true
	assert err == ''
	assert snapshot.status == 'bound'
	assert snapshot.message_id == 'om_reply_001'
	assert app.codex_runtime.stream_map['codex:task_002'].len == 1
	assert app.codex_runtime.stream_map['codex:task_002'][0].message_id == 'om_reply_001'
	assert 'om_reply_001' in app.feishu_buffers
	assert app.feishu_buffers['om_reply_001'].stream_id == 'codex:task_002'
}

fn test_feishu_handler_session_clear_message_removes_buffer_and_stream_target() {
	mut app := &App{
		codex_runtime: CodexProviderRuntime{
			thread_stream_map: map[string]string{}
			stream_map: {
				'codex:task_003': [
					CodexTarget{
						platform:   'feishu'
						message_id: 'om_reply_002'
					},
				]
			}
		}
		feishu_buffers: {
			'om_reply_002': FeishuStreamBuffer{
				message_id: 'om_reply_002'
				stream_id:  'codex:task_003'
			}
		}
	}
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:     'session.clear'
		provider:  'feishu'
		stream_id: 'codex:task_003'
		target:    'om_reply_002'
		target_type: 'message_id'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == true
	assert err == ''
	assert snapshot.status == 'cleared'
	assert 'om_reply_002' !in app.feishu_buffers
	assert 'codex:task_003' !in app.codex_runtime.stream_map
}

fn test_feishu_handler_session_clear_message_removes_buffer_chain() {
	mut app := &App{
		codex_runtime: CodexProviderRuntime{
			thread_stream_map: map[string]string{}
			stream_map: {
				'codex:task_chain': [
					CodexTarget{
						platform:   'feishu'
						message_id: 'om_chain_1'
					},
					CodexTarget{
						platform:   'feishu'
						message_id: 'om_chain_2'
					},
				]
			}
		}
		feishu_buffers: {
			'om_chain_1': FeishuStreamBuffer{
				message_id:    'om_chain_1'
				stream_id:     'codex:task_chain'
				next_message_id:'om_chain_2'
			}
			'om_chain_2': FeishuStreamBuffer{
				message_id: 'om_chain_2'
				stream_id:  'codex:task_chain'
			}
		}
	}
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:      'session.clear'
		provider:   'feishu'
		target:     'om_chain_1'
		target_type:'message_id'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == true
	assert err == ''
	assert snapshot.status == 'cleared'
	assert 'om_chain_1' !in app.feishu_buffers
	assert 'om_chain_2' !in app.feishu_buffers
	assert 'codex:task_chain' !in app.codex_runtime.stream_map
}

fn test_feishu_handler_session_clear_stream_id_removes_all_stream_buffers() {
	mut app := &App{
		codex_runtime: CodexProviderRuntime{
			thread_stream_map: map[string]string{}
			stream_map: {
				'codex:task_stream_clear': [
					CodexTarget{
						platform:   'feishu'
						message_id: 'om_stream_1'
					},
					CodexTarget{
						platform:   'feishu'
						message_id: 'om_stream_2'
					},
				]
			}
		}
		feishu_buffers: {
			'om_stream_1': FeishuStreamBuffer{
				message_id: 'om_stream_1'
				stream_id:  'codex:task_stream_clear'
			}
			'om_stream_2': FeishuStreamBuffer{
				message_id: 'om_stream_2'
				stream_id:  'codex:task_stream_clear'
			}
			'om_other': FeishuStreamBuffer{
				message_id: 'om_other'
				stream_id:  'codex:other'
			}
		}
	}
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := WorkerWebSocketUpstreamCommand{
		type_:     'session.clear'
		provider:  'feishu'
		stream_id: 'codex:task_stream_clear'
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snapshot := WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, normalized, mut snapshot)
	assert handled == true
	assert err == ''
	assert snapshot.status == 'cleared'
	assert 'om_stream_1' !in app.feishu_buffers
	assert 'om_stream_2' !in app.feishu_buffers
	assert 'om_other' in app.feishu_buffers
	assert 'codex:task_stream_clear' !in app.codex_runtime.stream_map
}
