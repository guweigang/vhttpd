module main

fn test_normalized_command_kind_for_legacy_type_mappings() {
	assert normalized_command_kind_for_legacy_type('codex.rpc.send') == 'provider.rpc.call'
	assert normalized_command_kind_for_legacy_type('codex.rpc.reply') == 'provider.rpc.reply'
	assert normalized_command_kind_for_legacy_type('codex.turn.start') == 'session.turn.start'
	assert normalized_command_kind_for_legacy_type('feishu.message.send') == 'provider.message.send'
	assert normalized_command_kind_for_legacy_type('feishu.message.update') == 'provider.message.update'
	assert normalized_command_kind_for_legacy_type('feishu.message.patch') == 'stream.append'
	assert normalized_command_kind_for_legacy_type('feishu.message.flush') == 'stream.finish'
	assert normalized_command_kind_for_legacy_type('discord.message.send') == 'provider.message.send'
	assert normalized_command_kind_for_legacy_type('discord.message.update') == 'provider.message.update'
	assert normalized_command_kind_for_legacy_type('session.bind') == 'session.bind'
}

fn test_normalized_command_infer_provider_prefers_declared_provider() {
	assert normalized_command_infer_provider('feishu.message.send', 'discord') == 'discord'
	assert normalized_command_infer_provider('codex.rpc.send', '') == 'codex'
	assert normalized_command_infer_provider('stream.append', 'feishu') == 'feishu'
	assert normalized_command_infer_provider('stream.append', '') == 'stream'
	assert normalized_command_infer_provider('', '') == ''
}

fn test_normalized_command_from_worker_command_preserves_correlation_and_metadata() {
	cmd := WorkerWebSocketUpstreamCommand{
		type_:       'codex.turn.start'
		provider:    'codex'
		instance:    'main'
		target:      'om_reply_001'
		target_type: 'message_id'
		stream_id:   'codex:task_123'
		session_key: 'session_abc'
		task_type:   'ask'
		prompt:      '请分析这个问题'
		method:      'turn/start'
		params:      '{"foo":"bar"}'
		metadata: {
			'thread_id':  'thread_001'
			'turn_id':    'turn_001'
			'request_id': 'req_001'
			'task_id':    'task_override'
			'cwd':        '/tmp/demo'
			'message_id': 'om_meta_001'
		}
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	assert normalized.kind == 'session.turn.start'
	assert normalized.provider == 'codex'
	assert normalized.target.id == 'om_reply_001'
	assert normalized.target.type_ == 'message_id'
	assert normalized.correlation.stream_id == 'codex:task_123'
	assert normalized.correlation.session_key == 'session_abc'
	assert normalized.correlation.task_id == 'task_123'
	assert normalized.correlation.thread_id == 'thread_001'
	assert normalized.correlation.turn_id == 'turn_001'
	assert normalized.correlation.request_id == 'req_001'
	assert normalized.task_type == 'ask'
	assert normalized.prompt == '请分析这个问题'
	assert normalized.working_dir == '/tmp/demo'
	assert normalized.response_message_id == 'om_reply_001'
	cwd := normalized.metadata['cwd'] or { '' }
	assert cwd == '/tmp/demo'
}

fn test_normalized_command_extracts_rpc_reply_fields_and_finish_semantics() {
	rpc_cmd := WorkerWebSocketUpstreamCommand{
		type_: 'codex.rpc.reply'
		metadata: {
			'id':     '42'
			'result': '{"ok":true}'
		}
	}
	rpc_normalized := NormalizedCommand.from_worker_command(rpc_cmd)
	assert rpc_normalized.rpc_id == '42'
	assert rpc_normalized.rpc_result == '{"ok":true}'
	assert rpc_normalized.stream_finish == false

	stream_cmd := WorkerWebSocketUpstreamCommand{
		type_: 'feishu.message.flush'
		metadata: {
			'finish': 'true'
		}
	}
	stream_normalized := NormalizedCommand.from_worker_command(stream_cmd)
	assert stream_normalized.kind == 'stream.finish'
	assert stream_normalized.stream_finish == true
}

fn test_normalized_command_response_message_id_prefers_target_message_id() {
	cmd := WorkerWebSocketUpstreamCommand{
		type_:       'codex.turn.start'
		target:      'om_target_001'
		target_type: 'message_id'
		metadata: {
			'message_id': 'om_meta_001'
		}
	}
	normalized := NormalizedCommand.from_worker_command(cmd)
	assert normalized.response_message_id == 'om_target_001'

	cmd_without_target := WorkerWebSocketUpstreamCommand{
		type_: 'codex.turn.start'
		metadata: {
			'message_id': 'om_meta_002'
		}
	}
	normalized_without_target := NormalizedCommand.from_worker_command(cmd_without_target)
	assert normalized_without_target.response_message_id == 'om_meta_002'
}

fn test_normalized_command_routing_and_kind_helpers() {
	send_cmd := NormalizedCommand{
		kind:     'provider.message.send'
		provider: 'feishu'
	}
	assert send_cmd.routing_type() == 'provider.message.send'
	assert send_cmd.is_provider_message() == true
	assert send_cmd.is_provider_message_send() == true
	assert send_cmd.is_provider_message_update() == false
	assert send_cmd.is_provider_rpc() == false
	assert send_cmd.is_stream_command() == false
	assert send_cmd.is_session_command() == false
	assert send_cmd.should_route_to_provider('feishu') == true
	assert send_cmd.should_route_to_provider('discord') == false

	stream_cmd := NormalizedCommand{
		kind:     'stream.append'
		provider: 'feishu'
	}
	assert stream_cmd.is_stream_command() == true
	assert stream_cmd.is_stream_append() == true
	assert stream_cmd.is_stream_finish() == false
	assert stream_cmd.should_route_to_provider('feishu') == true

	stream_fail_cmd := NormalizedCommand{
		kind:     'stream.fail'
		provider: 'feishu'
	}
	assert stream_fail_cmd.is_stream_command() == true
	assert stream_fail_cmd.is_stream_fail() == true
	assert stream_fail_cmd.should_route_to_provider('feishu') == true

	rpc_cmd := NormalizedCommand{
		kind:     'provider.rpc.call'
		provider: 'codex'
	}
	assert rpc_cmd.is_provider_rpc() == true
	assert rpc_cmd.is_provider_rpc_call() == true
	assert rpc_cmd.is_provider_rpc_reply() == false
	assert rpc_cmd.should_route_to_provider('codex') == true

	session_cmd := NormalizedCommand{
		kind:     'session.turn.start'
		provider: 'codex'
	}
	assert session_cmd.is_session_command() == true
	assert session_cmd.is_session_turn_start() == true
	assert session_cmd.is_session_bind() == false
	assert session_cmd.should_route_to_provider('codex') == true
	assert session_cmd.is_codex_control() == true

	session_bind_cmd := NormalizedCommand{
		kind:     'session.bind'
		provider: 'feishu'
	}
	assert session_bind_cmd.is_session_bind() == true
	assert session_bind_cmd.is_session_clear() == false

	update_cmd := NormalizedCommand{
		kind:     'provider.message.update'
		provider: 'feishu'
	}
	assert update_cmd.is_provider_message_update() == true

	stream_finish_cmd := NormalizedCommand{
		kind:     'stream.finish'
		provider: 'feishu'
	}
	assert stream_finish_cmd.is_stream_finish() == true
}

fn test_normalized_command_event_inference() {
	send_cmd := NormalizedCommand{
		kind: 'provider.message.send'
	}
	assert send_cmd.normalized_event('') == 'send'

	update_cmd := NormalizedCommand{
		kind: 'provider.message.update'
	}
	assert update_cmd.normalized_event('') == 'update'

	append_cmd := NormalizedCommand{
		kind: 'stream.append'
	}
	assert append_cmd.normalized_event('') == 'update'

	finish_cmd := NormalizedCommand{
		kind: 'stream.finish'
	}
	assert finish_cmd.normalized_event('') == 'update'

	explicit_event_cmd := NormalizedCommand{
		kind:  'provider.message.send'
		event: 'custom_event'
	}
	assert explicit_event_cmd.normalized_event('send') == 'custom_event'

	default_event_cmd := NormalizedCommand{
		kind: 'session.bind'
	}
	assert default_event_cmd.normalized_event('dispatch') == 'dispatch'
}

fn test_normalized_command_routing_type_prefers_legacy_type_for_compatibility() {
	cmd := NormalizedCommand{
		legacy_type: 'feishu.message.patch'
		kind:        'stream.append'
	}
	assert cmd.routing_type() == 'feishu.message.patch'
}

fn test_command_envelope_legacy_helpers_remain_stable() {
	cmd := WorkerWebSocketUpstreamCommand{
		type_:    'feishu.message.send'
		provider: ''
		instance: 'main'
		target:   'oc_123'
		content:  '{"text":"hello"}'
		metadata: {
			'trace_id': 'trace_001'
		}
	}
	envelope := CommandEnvelope.from_worker_command(cmd)
	assert envelope.type_ == 'feishu.message.send'
	assert envelope.target == 'oc_123'
	assert envelope.payload == '{"text":"hello"}'
	trace_id := envelope.metadata['trace_id'] or { '' }
	assert trace_id == 'trace_001'
	assert envelope.is_codex_control() == false
	assert envelope.normalized_provider('feishu') == 'feishu'
	assert envelope.normalized_event('') == 'send'
}
