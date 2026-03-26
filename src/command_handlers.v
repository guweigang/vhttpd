module main

import log

pub struct CodexCommandHandler {
pub mut:
	app &App = unsafe { nil }
}

pub fn CodexCommandHandler.new(mut app App) CodexCommandHandler {
	return CodexCommandHandler{
		app: app
	}
}

pub fn (h CodexCommandHandler) execute(command WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	mut app := h.app
	_ = command
	if normalized.provider != 'codex' {
		return false, ''
	}
	if normalized.is_session_bind() {
		if normalized.correlation.stream_id != '' && normalized.target.type_ == 'thread_id'
			&& normalized.target.id != '' {
			app.codex_mu.@lock()
			app.codex_runtime.bind_stream_to_thread(normalized.target.id, normalized.correlation.stream_id)
			app.codex_mu.unlock()
			snapshot.status = 'bound'
			return true, ''
		}
		if normalized.correlation.stream_id != '' && normalized.target.type_ == 'message_id'
			&& normalized.target.id != '' {
			app.codex_mu.@lock()
			app.codex_runtime.add_stream_target(normalized.correlation.stream_id, CodexTarget{
				platform:   'feishu'
				message_id: normalized.target.id
			})
			app.codex_mu.unlock()
			snapshot.status = 'bound'
			return true, ''
		}
		return false, ''
	}
	if normalized.is_session_clear() {
		mut cleared := false
		if normalized.target.type_ == 'thread_id' && normalized.target.id != '' {
			app.codex_mu.@lock()
			cleared = app.codex_runtime.clear_thread_binding(normalized.target.id)
			app.codex_mu.unlock()
		} else if normalized.correlation.thread_id != '' {
			app.codex_mu.@lock()
			cleared = app.codex_runtime.clear_thread_binding(normalized.correlation.thread_id)
			app.codex_mu.unlock()
		}
		if !cleared && normalized.correlation.stream_id != '' {
			app.codex_mu.@lock()
			cleared = app.codex_runtime.clear_stream_targets(normalized.correlation.stream_id)
			app.codex_mu.unlock()
		}
		if cleared {
			snapshot.status = 'cleared'
			return true, ''
		}
		return false, ''
	}
	if normalized.is_session_turn_start() {
		app.codex_start_turn_normalized(normalized) or {
			log.error('[ws-cmd]   codex.turn.start FAILED: ${err}')
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		log.info('[ws-cmd]   codex.turn.start OK')
		snapshot.status = 'started'
		return true, ''
	}

	if normalized.is_provider_rpc_reply() {
		id_raw := normalized.rpc_id
		result := normalized.rpc_result
		app.codex_reply_rpc(id_raw, result) or {
			log.error('[ws-cmd]   codex.rpc.reply FAILED: ${err}')
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		log.info('[ws-cmd]   codex.rpc.reply OK: id=${id_raw}')
		snapshot.status = 'replied'
		return true, ''
	}

	if normalized.is_provider_rpc_call() {
		method := normalized.method
		params := normalized.params
		app.codex_send_rpc(method, params, normalized.correlation.stream_id, '') or {
			log.error('[ws-cmd]   codex.rpc.send FAILED: ${err}')
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		log.info('[ws-cmd]   codex.rpc.send OK: method=${method}')
		snapshot.status = 'sent'
		return true, ''
	}

	return false, ''
}

pub struct FeishuCommandHandler {
pub mut:
	app &App = unsafe { nil }
}

pub fn FeishuCommandHandler.new(mut app App) FeishuCommandHandler {
	return FeishuCommandHandler{
		app: app
	}
}

fn websocket_upstream_request_from_normalized(normalized NormalizedCommand, default_provider string) WebSocketUpstreamSendRequest {
	return WebSocketUpstreamSendRequest{
		provider:       normalized.normalized_provider(default_provider)
		instance:       normalized.instance
		target_type:    normalized.target.type_
		target:         normalized.target.id
		message_type:   normalized.message_type
		content:        normalized.content
		content_fields: normalized.content_fields.clone()
		text:           normalized.text
		uuid:           normalized.uuid
		method:         normalized.method
		params:         normalized.params
		metadata:       normalized.metadata.clone()
	}
}

fn feishu_command_request_from_normalized(normalized NormalizedCommand) WebSocketUpstreamSendRequest {
	return websocket_upstream_request_from_normalized(normalized, 'feishu')
}

fn (h FeishuCommandHandler) resolve_target(normalized NormalizedCommand, mut req WebSocketUpstreamSendRequest) {
	if req.target != '' || normalized.correlation.stream_id == '' {
		return
	}
	mut app := h.app
	app.codex_mu.@lock()
	targets := app.codex_runtime.stream_map[normalized.correlation.stream_id].clone()
	app.codex_mu.unlock()
	platform := normalized.normalized_provider('feishu')
	for t in targets.reverse() {
		if t.platform == platform {
			log.info('[ws-cmd]   💡 resolved stream_id=${normalized.correlation.stream_id} → target=${t.message_id} (platform=${platform})')
			req.target = t.message_id
			break
		}
	}
}

fn feishu_command_normalize_stream_send(normalized NormalizedCommand, req WebSocketUpstreamSendRequest) WebSocketUpstreamSendRequest {
	if normalized.correlation.stream_id.trim_space() == '' {
		return req
	}
	return feishu_runtime_normalize_streaming_send(req)
}

fn (h FeishuCommandHandler) execute_provider_message_send(normalized NormalizedCommand, mut req WebSocketUpstreamSendRequest, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	req = feishu_command_normalize_stream_send(normalized, req)
	if normalized.correlation.stream_id != '' && req.message_type == 'interactive' {
		log.info('[ws-cmd]   🎴 normalized feishu stream send to interactive placeholder')
	}
	mut app := h.app
	result := app.websocket_upstream_send(req) or {
		snapshot.status = 'error'
		snapshot.error = err.msg()
		return true, err.msg()
	}
	snapshot.status = 'sent'
	snapshot.message_id = result.message_id
	log.info('[ws-cmd]   send OK: msg_id=${result.message_id}')
	if normalized.correlation.stream_id != '' {
		log.info('[ws-cmd]   🔗 registering stream_id=${normalized.correlation.stream_id} → platform=${normalized.provider} message_id=${result.message_id}')
		app.codex_mu.@lock()
		mut found := false
		platform := normalized.provider
		for t in app.codex_runtime.stream_map[normalized.correlation.stream_id] {
			if t.platform == platform && t.message_id == result.message_id {
				found = true
				break
			}
		}
		if !found {
			app.codex_runtime.stream_map[normalized.correlation.stream_id] << CodexTarget{
				platform:   platform
				message_id: result.message_id
			}
		}
		app.codex_mu.unlock()
		app.feishu_runtime_register_stream_buffer(result.message_id, normalized.correlation.stream_id, req.instance, req.target, req.target_type)
	}
	app.dispatch_feishu_message_sent(normalized.correlation.stream_id, result.message_id)
	return true, ''
}

fn (h FeishuCommandHandler) execute_stream_command(normalized NormalizedCommand, req WebSocketUpstreamSendRequest, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	mut app := h.app
	if normalized.is_stream_append() && req.target != '' {
		log.info('[ws-cmd]   📥 buffering patch for target=${req.target}')
		app.feishu_runtime_buffer_patch(req)
		snapshot.status = 'buffered'
		return true, ''
	}
	if normalized.is_stream_finish() && req.target != '' {
		app.feishu_runtime_flush_buffer(req.target, req.content, normalized.stream_finish) or {
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		snapshot.status = if normalized.stream_finish { 'finished' } else { 'flushed' }
		return true, ''
	}
	if normalized.is_stream_fail() && req.target != '' {
		app.feishu_runtime_clear_buffer(req.target)
		result := app.websocket_upstream_update(req) or {
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		snapshot.status = 'failed'
		snapshot.message_id = result.message_id
		app.dispatch_feishu_message_updated(normalized.correlation.stream_id, result.message_id)
		return true, ''
	}
	return false, ''
}

fn (h FeishuCommandHandler) execute_provider_message_update(normalized NormalizedCommand, req WebSocketUpstreamSendRequest, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	mut app := h.app
	if req.target != '' {
		app.feishu_runtime_clear_buffer(req.target)
	}
	result := app.websocket_upstream_update(req) or {
		snapshot.status = 'error'
		snapshot.error = err.msg()
		return true, err.msg()
	}
	log.info('[ws-cmd]   update OK: target=${result.message_id}')
	snapshot.status = 'updated'
	snapshot.message_id = result.message_id
	app.dispatch_feishu_message_updated(normalized.correlation.stream_id, result.message_id)
	return true, ''
}

pub fn (h FeishuCommandHandler) execute(command WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	_ = command
	if normalized.normalized_provider('') != 'feishu' {
		return false, ''
	}
	if normalized.is_session_bind() {
		if normalized.correlation.stream_id != '' && normalized.target.type_ == 'message_id'
			&& normalized.target.id != '' {
			mut app := h.app
			app.codex_mu.@lock()
			app.codex_runtime.add_stream_target(normalized.correlation.stream_id, CodexTarget{
				platform:   'feishu'
				message_id: normalized.target.id
			})
			app.codex_mu.unlock()
			app.feishu_runtime_register_stream_buffer(normalized.target.id, normalized.correlation.stream_id, normalized.instance, '', '')
			snapshot.status = 'bound'
			snapshot.message_id = normalized.target.id
			return true, ''
		}
		return false, ''
	}
	if normalized.is_session_clear() {
		mut cleared := false
		mut app := h.app
		if normalized.target.type_ == 'message_id' && normalized.target.id != '' {
			app.feishu_runtime_clear_buffer(normalized.target.id)
			if normalized.correlation.stream_id != '' {
				app.codex_mu.@lock()
				cleared = app.codex_runtime.remove_stream_target(normalized.correlation.stream_id, 'feishu', normalized.target.id)
				app.codex_mu.unlock()
			}
			cleared = true
		} else if normalized.correlation.stream_id != '' {
			app.codex_mu.@lock()
			cleared = app.codex_runtime.clear_stream_targets(normalized.correlation.stream_id)
			app.codex_mu.unlock()
		}
		if cleared {
			snapshot.status = 'cleared'
			return true, ''
		}
		return false, ''
	}
	resolved_event := normalized.normalized_event('')
	resolved_provider := normalized.normalized_provider('feishu')
	if resolved_event !in ['send', 'update'] {
		return false, ''
	}

	mut req := feishu_command_request_from_normalized(normalized)
	req.provider = resolved_provider
	h.resolve_target(normalized, mut req)

	if normalized.is_provider_message_send() || resolved_event == 'send' {
		return h.execute_provider_message_send(normalized, mut req, mut snapshot)
	}

	if normalized.is_stream_command() {
		handled, err := h.execute_stream_command(normalized, req, mut snapshot)
		if handled {
			return handled, err
		}
	}

	return h.execute_provider_message_update(normalized, req, mut snapshot)
}

pub struct GenericUpstreamCommandHandler {
pub mut:
	app &App = unsafe { nil }
}

pub fn GenericUpstreamCommandHandler.new(mut app App) GenericUpstreamCommandHandler {
	return GenericUpstreamCommandHandler{
		app: app
	}
}

pub fn (h GenericUpstreamCommandHandler) execute(command WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	_ = command
	if normalized.kind == 'admin.worker.restart_all' {
		mut app := h.app
		restarted := app.restart_all_workers()
		snapshot.status = 'restarted'
		snapshot.error = ''
		snapshot.provider = 'admin'
		snapshot.event = 'restart_all'
		snapshot.target = '${restarted}'
		return true, ''
	}
	if normalized.normalized_provider('') == 'feishu' {
		return false, ''
	}
	resolved_event := normalized.normalized_event('')
	resolved_provider := normalized.normalized_provider('')
	if resolved_event !in ['send', 'update'] {
		return false, ''
	}

	mut req := websocket_upstream_request_from_normalized(normalized, '')
	req.provider = resolved_provider
	mut app := h.app
	if resolved_event == 'send' {
		result := app.websocket_upstream_send(req) or {
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		snapshot.status = 'sent'
		snapshot.message_id = result.message_id
		return true, ''
	}
	result := app.websocket_upstream_update(req) or {
		snapshot.status = 'error'
		snapshot.error = err.msg()
		return true, err.msg()
	}
	snapshot.status = 'updated'
	snapshot.message_id = result.message_id
	return true, ''
}
