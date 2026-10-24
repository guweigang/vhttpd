module main

import upstream.transport
import command as cmdpkg
import codex
import executor
import log
import upstream
import feishu

pub struct CodexCommandHandler {
pub mut:
	app CodexCommandHost @[required]
}

pub fn CodexCommandHandler.new(mut app CodexCommandHost) CodexCommandHandler {
	return CodexCommandHandler{
		app: app
	}
}

pub fn (h CodexCommandHandler) execute(command transport.WorkerWebSocketUpstreamCommand, normalized cmdpkg.NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	mut app := h.app
	_ = command
	if normalized.provider != 'codex' {
		return false, ''
	}
	if normalized.is_session_bind() {
		instance := codex.ProviderRuntime.normalize_instance(normalized.instance)
		if normalized.correlation.stream_id != '' && normalized.target.type_ == 'thread_id'
			&& normalized.target.id != '' {
			app.codex_bind_stream_to_thread(instance, normalized.target.id,
				normalized.correlation.stream_id)
			snapshot.status = 'bound'
			return true, ''
		}
		if normalized.correlation.stream_id != '' && normalized.target.type_ == 'message_id'
			&& normalized.target.id != '' {
			app.codex_add_stream_target(instance, normalized.correlation.stream_id, codex.CodexTarget{
				platform:   'feishu'
				message_id: normalized.target.id
			})
			snapshot.status = 'bound'
			return true, ''
		}
		return false, ''
	}
	if normalized.is_session_clear() {
		instance := codex.ProviderRuntime.normalize_instance(normalized.instance)
		mut cleared := false
		if normalized.target.type_ == 'thread_id' && normalized.target.id != '' {
			cleared = app.codex_clear_thread_binding(instance, normalized.target.id)
		} else if normalized.correlation.thread_id != '' {
			cleared = app.codex_clear_thread_binding(instance, normalized.correlation.thread_id)
		}
		if !cleared && normalized.correlation.stream_id != '' {
			cleared = app.codex_clear_stream_targets(instance, normalized.correlation.stream_id)
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
		app.codex_reply_rpc(normalized.instance, id_raw, result) or {
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
		app.codex_send_rpc(normalized.instance, method, params, normalized.correlation.stream_id,
			'') or {
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
	app FeishuCommandHost @[required]
}

pub fn FeishuCommandHandler.new(mut app FeishuCommandHost) FeishuCommandHandler {
	return FeishuCommandHandler{
		app: app
	}
}

fn (h FeishuCommandHandler) resolve_target(normalized cmdpkg.NormalizedCommand, mut req upstream.UpstreamSendRequest) {
	if req.target != '' || normalized.correlation.stream_id == '' {
		return
	}
	mut app := h.app
	targets := app.codex_find_stream_targets(normalized.correlation.stream_id)
	platform := normalized.normalized_provider('feishu')
	for t in targets.reverse() {
		if t.platform == platform {
			log.info('[ws-cmd]   💡 resolved stream_id=${normalized.correlation.stream_id} → target=${t.message_id} (platform=${platform})')
			req.target = t.message_id
			break
		}
	}
}

fn (h FeishuCommandHandler) execute_provider_message_send(normalized cmdpkg.NormalizedCommand, mut req upstream.UpstreamSendRequest, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	req = feishu.SendMessageRequest.normalize_upstream_for_streaming_if_needed(req, normalized)
	if normalized.correlation.stream_id.trim_space() != '' {
		req.metadata['stream_id'] = normalized.correlation.stream_id
	}
	if normalized.correlation.stream_id != '' && req.message_type == 'interactive' {
		log.info('[ws-cmd]   🎴 normalized feishu stream send to interactive placeholder')
	}
	mut app := h.app
	mut feishu_state := app.command_feishu_state()
	publication_id := req.metadata['publication_id'] or { '' }
	claim := feishu_state.admit_wire_initial_creation(normalized.correlation.stream_id, req.instance, req.metadata['stream_generation'] or { '' }, req.metadata['creation_token'] or { '' }) or { return feishu_stream_command_error(mut snapshot, 'feishu_initial_send_retired') }
	defer { feishu_state.finish_initial_send(claim) }
	result := app.websocket_upstream_send(req) or {
		snapshot.status = 'error'
		snapshot.error = err.msg()
		return true, err.msg()
	}
	snapshot.status = 'sent'
	snapshot.message_id = result.message_id
	log.info('[ws-cmd]   send OK: msg_id=${result.message_id}')
	if normalized.correlation.stream_id != '' {
		if !result.ok {
			snapshot.status = 'error'
			snapshot.error = if result.error != '' {
				result.error
			} else {
				'feishu_initial_send_failed'
			}
			return true, snapshot.error
		}
		// Commit the HTTP result and target under the same owner lock as bind
		// and clear. Neither HTTP nor notification callbacks run under it.
		feishu_state.mu.@lock()
		if feishu.is_one_shot_reply_stream(normalized.correlation.stream_id) {
			generation := req.metadata['stream_generation'] or { '' }
			completed := (result.stream_generation == '' || result.stream_generation == generation)
				&& feishu_state.complete_initial_reply_unlocked(claim, result.message_id, generation)
			feishu_state.mu.unlock()
			if !completed {
				return feishu_stream_command_error(mut snapshot, 'feishu_initial_send_retired')
			}
			snapshot.stream_generation = generation
			return true, ''
		}
		if !feishu_state.commit_initial_send_generation_unlocked(claim, result.message_id,
			req.instance, req.target, req.target_type, req.text, if result.stream_generation != '' {
				result.stream_generation
			} else {
				req.metadata['stream_generation'] or { '' }
			}) {
			feishu_state.mu.unlock()
			snapshot.status = 'error'
			snapshot.error = 'feishu_initial_send_retired'
			return true, snapshot.error
		}
		if result.stream_generation != '' {
			feishu_state.mark_bridge_replica_unlocked(result.message_id)
		}
		log.info('[ws-cmd]   🔗 registering stream_id=${normalized.correlation.stream_id} → platform=${normalized.provider} message_id=${result.message_id}')
		// The admitted result owns this physical message. Replace stale target
		// entries as well as publishing provenance, rather than retaining an older
		// generation merely because its message ID already appears in the index.
		app.codex_rebind_stream_target(app.codex_resolve_instance_for_stream(normalized.correlation.stream_id),
			normalized.correlation.stream_id, codex.CodexTarget{
				platform:          normalized.provider
				message_id:        result.message_id
				stream_generation: feishu_state.stream_generation_unlocked(result.message_id)
				buffer_message_id: result.message_id
			})
		snapshot.stream_generation = feishu_state.stream_generation_unlocked(result.message_id)
		feishu_state.start_sent_publication_unlocked(result.message_id, publication_id)
		receipt := feishu_state.next_sent_receipt_unlocked(result.message_id, result.message_id)
		feishu_state.mu.unlock()
		app.dispatch_feishu_message_sent(receipt)
	}
	return true, ''
}

fn feishu_stream_command_error(mut snapshot executor.WebSocketUpstreamCommandActivity, message string) (bool, string) {
	snapshot.status = 'error'
	snapshot.error = message
	return true, message
}

fn (h FeishuCommandHandler) execute_stream_command(normalized cmdpkg.NormalizedCommand, req upstream.UpstreamSendRequest, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	mut app := h.app
	mut state := app.command_feishu_state()
	metadata_stream := req.metadata['stream_id'] or { '' }
	stream_id := if normalized.correlation.stream_id != '' {
		normalized.correlation.stream_id
	} else {
		metadata_stream
	}
	if metadata_stream != '' && metadata_stream != stream_id {
		return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
	}
	use_bridge := app.command_feishu_bridge_enabled()
	mut gate := ?feishu.BridgeStreamGateLease(none)
	if use_bridge {
		gate = state.acquire_bridge_stream_gate(req.target, stream_id, req.instance, req.metadata['stream_generation'] or { '' }) or {
			return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
		}
	}
	defer { if lease := gate { lease.release() } }
	admission := state.admit_wire_stream_command(req.target, stream_id, req.instance, req.metadata['stream_generation'] or { '' }) or {
		return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
	}
	mut request := upstream.UpstreamSendRequest{ ...req, metadata: req.metadata.clone() }
	request.metadata['stream_id'] = stream_id
	request.metadata['feishu_stream_finish'] = normalized.stream_finish.str()
	action := if normalized.is_stream_append() {
		'append'
	} else if normalized.is_stream_finish() {
		'finish'
	} else {
		'fail'
	}
	mut result := upstream.UpstreamUpdateResult{}
	if use_bridge {
		// A host callback may have replaced the buffer after admission.
		owned := state.stream_command_snapshot(admission) or {
			return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
		}
		request.instance = owned.app
		result = h.execute_bridge_stream_operation(admission, request, action) or { return feishu_stream_command_error(mut snapshot, err.msg()) }
	} else {
		result = app.feishu_runtime_execute_stream_command(admission, request, action, normalized.stream_finish) or {
			return feishu_stream_command_error(mut snapshot, err.msg())
		}
	}
	if !result.ok {
		return feishu_stream_command_error(mut snapshot, if result.error != '' {
			result.error
		} else {
			'feishu_stream_command_failed'
		})
	}
	snapshot.stream_generation = req.metadata['stream_generation'] or { '' }
	snapshot.status = match action {
		'append' { 'buffered' }
		'finish' {
			if normalized.stream_finish { 'finished' } else { 'flushed' }
		}
		else { 'failed' }
	}
	snapshot.message_id = result.message_id
	if action == 'fail' { app.dispatch_feishu_message_updated(stream_id, result.message_id) }
	return true, ''
}

fn (h FeishuCommandHandler) execute_provider_message_update(normalized cmdpkg.NormalizedCommand, req upstream.UpstreamSendRequest, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	mut app := h.app
	mut state := app.command_feishu_state()
	stream := normalized.correlation.stream_id
	if (req.metadata['stream_id'] or { stream }) != stream {
		return feishu_stream_command_error(mut snapshot, 'feishu_message_update_retired')
	}
	generation := req.metadata['stream_generation'] or { '' }
	gate := state.acquire_bridge_stream_gate(req.target, stream, req.instance, generation) or { return feishu_stream_command_error(mut snapshot, 'feishu_message_update_retired') }
	defer { gate.release() }
	bridge := app.command_feishu_bridge_enabled()
	claim := state.admit_wire_message_update(req.target, stream, req.instance, generation, bridge) or { return feishu_stream_command_error(mut snapshot, 'feishu_message_update_retired') }
	defer { state.cancel_message_update(claim) }
	mut request := upstream.UpstreamSendRequest{ ...req, metadata: req.metadata.clone(), instance: claim.buffer.app }
	request.metadata['stream_id'] = stream
	request.metadata['feishu_update_captured_content'] = claim.buffer.content
	mut result := upstream.UpstreamUpdateResult{}
	if bridge {
		if mut app is FeishuMessageUpdateBridgeHost {
			result = app.command_feishu_bridge_message_update(claim, request) or { return feishu_stream_command_error(mut snapshot, err.msg()) }
			if !feishu.valid_message_update_result(claim, result.stream_generation, result.stream_state) {
				return feishu_stream_command_error(mut snapshot, 'feishu_message_update_retired')
			}
		} else {
			return feishu_stream_command_error(mut snapshot, 'bridge_update_unavailable')
		}
	} else {
		if !state.message_update_is_current(claim) {
			return feishu_stream_command_error(mut snapshot, 'feishu_message_update_retired')
		}
		result = app.websocket_upstream_update(request) or { return feishu_stream_command_error(mut snapshot, err.msg()) }
	}
	if !result.ok || result.message_id != claim.buffer.message_id {
		return feishu_stream_command_error(mut snapshot, if result.error != '' {
			result.error
		} else {
			'feishu_message_update_failed'
		})
	}
	if !state.complete_message_update(claim) {
		return feishu_stream_command_error(mut snapshot, 'feishu_message_update_retired')
	}
	snapshot.status = 'updated'
	snapshot.message_id = claim.buffer.message_id
	snapshot.stream_generation = claim.buffer.generation
	app.dispatch_feishu_message_updated(claim.buffer.stream_id, claim.buffer.message_id)
	return true, ''
}

pub fn (h FeishuCommandHandler) execute(command transport.WorkerWebSocketUpstreamCommand, normalized cmdpkg.NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	_ = command
	if normalized.normalized_provider('') != 'feishu' {
		return false, ''
	}
	if normalized.is_session_bind() {
		if normalized.correlation.stream_id != '' && normalized.target.type_ == 'message_id'
			&& normalized.target.id != '' {
			mut app := h.app
			mut feishu_state := app.command_feishu_state()
			if app.command_feishu_bridge_enabled() {
				if mut app is FeishuBridgeBindingHost {
					feishu_state.mu.@lock()
					admitted := feishu_state.begin_bridge_bind_unlocked(normalized.target.id, normalized.correlation.stream_id, normalized.instance,
						normalized.metadata['stream_generation'] or { '' }, normalized.metadata['creation_generation'] or { '' }, normalized.metadata['creation_token'] or { '' }) or {
						feishu_state.mu.unlock()
						return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
					}
					claim := feishu.BridgeBind{ ...admitted, publication_id: normalized.metadata['publication_id'] or { '' } }
					feishu_state.mu.unlock()
					generation := app.command_feishu_bridge_bind(claim) or {
						feishu_state.mu.@lock()
						if released := feishu_state.abort_bridge_bind_unlocked(claim) {
							app.codex_release_feishu_targets(released)
						}
						feishu_state.mu.unlock()
						return feishu_stream_command_error(mut snapshot, err.msg())
					}
					feishu_state.mu.@lock()
					if !feishu_state.complete_bridge_bind_unlocked(claim, generation) {
						if released := feishu_state.abort_bridge_bind_unlocked(claim) {
							app.codex_release_feishu_targets(released)
						}
						feishu_state.mu.unlock()
						app.command_feishu_bridge_cancel_bind(claim, generation) or {
							return feishu_stream_command_error(mut snapshot, err.msg())
						}
						return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
					}
					app.codex_rebind_stream_target(app.codex_resolve_instance_for_stream(claim.stream), claim.stream,
						codex.CodexTarget{ platform: 'feishu', message_id: claim.message, buffer_message_id: claim.message, stream_generation: generation })
					feishu_state.start_sent_publication_unlocked(claim.message, normalized.metadata['publication_id'] or { '' })
					receipt := feishu_state.next_sent_receipt_unlocked(claim.message, claim.message)
					feishu_state.mu.unlock()
					app.dispatch_feishu_message_sent(receipt)
					snapshot.stream_generation = generation
					snapshot.status = 'bound'
					snapshot.message_id = claim.message
					return true, ''
				}
				return feishu_stream_command_error(mut snapshot, 'bridge_bind_unavailable')
			}
			// Match session.clear and async completion publication: Feishu then
			// Codex, with no callback or I/O inside the paired transition.
			feishu_state.mu.@lock()
			binding := feishu_state.wire_bind_bridge_binding_unlocked(normalized.target.id, normalized.metadata['creation_token'] or { '' })
			if !feishu_state.admit_wire_bind_unlocked(normalized.target.id, normalized.correlation.stream_id, normalized.instance, normalized.metadata['stream_generation'] or { '' }, normalized.metadata['creation_generation'] or { '' }, normalized.metadata['creation_token'] or { '' }) {
				feishu_state.mu.unlock()
				return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
			}
			feishu_state.register_stream_buffer_unlocked(normalized.target.id,
				normalized.correlation.stream_id, normalized.instance, '', '', '')
			feishu_state.retain_bridge_binding_unlocked(normalized.target.id, binding)
			app.codex_rebind_stream_target(app.codex_resolve_instance_for_stream(normalized.correlation.stream_id),
				normalized.correlation.stream_id, codex.CodexTarget{
					platform:          'feishu'
					message_id:        normalized.target.id
					stream_generation: feishu_state.stream_generation_unlocked(normalized.target.id)
					buffer_message_id: normalized.target.id
				})
			snapshot.stream_generation = feishu_state.stream_generation_unlocked(normalized.target.id)
			feishu_state.start_sent_publication_unlocked(normalized.target.id, normalized.metadata['publication_id'] or { '' })
			receipt := feishu_state.next_sent_receipt_unlocked(normalized.target.id, normalized.target.id)
			feishu_state.mu.unlock()
			app.dispatch_feishu_message_sent(receipt)
			snapshot.status = 'bound'
			snapshot.message_id = normalized.target.id
			return true, ''
		}
		return false, ''
	}
	if normalized.is_session_clear() {
		mut app := h.app
		mut state := app.command_feishu_state()
		if normalized.target.id != '' && normalized.target.type_ != 'message_id' {
			return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
		}
		state.mu.@lock()
		released := state.release_wire_stream_unlocked(normalized.target.id, normalized.correlation.stream_id, normalized.instance, normalized.metadata['stream_generation'] or { '' }) or {
			state.mu.unlock()
			// An already completed reply has nothing left to revoke. This is an
			// idempotent no-op, never a lookup or release of a newer generation.
			if normalized.target.id == '' && feishu.is_one_shot_reply_stream(normalized.correlation.stream_id)
				&& (normalized.metadata['stream_generation'] or { '' }) != '' {
				snapshot.status = 'cleared'
				return true, ''
			}
			return feishu_stream_command_error(mut snapshot, 'feishu_stream_command_retired')
		}
		app.codex_release_feishu_targets(released)
		state.mu.unlock()
		if app.command_feishu_bridge_enabled() {
			if mut app is FeishuBridgeRevocationHost {
				app.command_feishu_bridge_proxy_clear(upstream.UpstreamSendRequest{
					provider:    'feishu'
					instance:    normalized.instance
					target:      normalized.target.id
					target_type: normalized.target.type_
					metadata:    {
						'stream_id':         normalized.correlation.stream_id
						'stream_generation': released.generation
					}
				}, released) or { return feishu_stream_command_error(mut snapshot, err.msg()) }
			} else {
				return feishu_stream_command_error(mut snapshot, 'bridge_revoke_unavailable')
			}
		}
		snapshot.status = 'cleared'
		return true, ''
	}
	resolved_event := normalized.normalized_event('')
	resolved_provider := normalized.normalized_provider('feishu')
	if !normalized.is_stream_command() && resolved_event !in ['send', 'update'] {
		return false, ''
	}

	mut req := upstream.UpstreamSendRequest.from_feishu_command(normalized)
	req.provider = resolved_provider
	h.resolve_target(normalized, mut req)

	if normalized.is_stream_command() {
		return h.execute_stream_command(normalized, req, mut snapshot)
	}
	if normalized.is_provider_message_send() || resolved_event == 'send' {
		return h.execute_provider_message_send(normalized, mut req, mut snapshot)
	}

	return h.execute_provider_message_update(normalized, req, mut snapshot)
}

pub struct GenericUpstreamCommandHandler {
pub mut:
	app GenericCommandHost @[required]
}

pub fn GenericUpstreamCommandHandler.new(mut app GenericCommandHost) GenericUpstreamCommandHandler {
	return GenericUpstreamCommandHandler{
		app: app
	}
}

pub fn (h GenericUpstreamCommandHandler) execute(command transport.WorkerWebSocketUpstreamCommand, normalized cmdpkg.NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
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

	// Codex has no message replacement operation. Treating update as a raw
	// socket send bypasses its RPC/control admission and can target a reconnect.
	if resolved_event in ['send', 'update'] && resolved_provider in ['codex', ''] {
		snapshot.status = 'error'
		snapshot.error = if resolved_provider == '' {
			'provider_message_${resolved_event}_provider_required'
		} else {
			'codex_message_${resolved_event}_unsupported_use_rpc'
		}
		return true, snapshot.error
	}

	mut req := upstream.UpstreamSendRequest.from_normalized(normalized, '')
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

fn (h FeishuCommandHandler) proxy_bridge_stream_operation(op feishu.BridgeStreamOperation, req upstream.UpstreamSendRequest, action string) !upstream.UpstreamUpdateResult {
	mut app := h.app
	if mut app is FeishuBridgeStreamCompletionHost {
		return app.command_feishu_bridge_stream_operation(req, op, action)
	}
	return match action {
		'append' { app.command_feishu_bridge_proxy_append(req)! }
		'finish' { app.command_feishu_bridge_proxy_finish(req)! }
		else { app.command_feishu_bridge_proxy_fail(req)! }
	}
}

fn (h FeishuCommandHandler) execute_bridge_stream_operation(admission feishu.StreamCommand, req upstream.UpstreamSendRequest, action string) !upstream.UpstreamUpdateResult {
	mut app := h.app
	mut state := app.command_feishu_state()
	op := state.begin_bridge_stream_operation(admission, app is FeishuBridgeStreamCompletionHost) or { return error('feishu_stream_command_retired') }
	mut accepted := false
	defer {
		if !accepted {
			state.mu.@lock()
			if released := state.abort_bridge_stream_operation_unlocked(op) {
				app.codex_release_feishu_targets(released)
			}
			state.mu.unlock()
		}
	}
	result := h.proxy_bridge_stream_operation(op, req, action)!
	state.mu.@lock()
	if !result.ok || result.message_id != op.buffer.message_id || !state.complete_bridge_stream_operation_unlocked(op, action, result.stream_generation, result.stream_state) {
		state.mu.unlock()
		if mut app is FeishuBridgeStreamCompletionHost {
			app.command_feishu_bridge_cancel_stream_operation(op)!
		}
		return error('feishu_stream_command_retired')
	}
	if action == 'fail' {
		if released := state.abort_bridge_stream_operation_unlocked(op) {
			app.codex_release_feishu_targets(released)
		}
	}
	state.mu.unlock()
	accepted = true
	return result
}
