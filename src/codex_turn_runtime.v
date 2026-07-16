module main

import command
import json
import log
import time
import upstream
import codex

// ── Turn Management ─────────────────────────────────────────────────────

fn (mut app App) codex_start_turn_normalized(cmd command.NormalizedCommand) ! {
	log.info('[codex] 🚀 codex_start_turn stream_id=${cmd.correlation.stream_id} task_type=${cmd.task_type} prompt=${cmd.prompt}')
	instance := codex.ProviderRuntime.normalize_instance(cmd.instance)
	cfg := app.providers.codex.snapshot(instance)
	mut rt := app.codex_runtime_ensure_instance(instance)

	// Ensure provider is connected
	if !rt.is_connected() {
		return error('codex provider not connected')
	}
	if !rt.is_initialized() {
		return error('codex provider not initialized')
	}

	stream_id := cmd.correlation.stream_id
	if stream_id == '' {
		return error('codex stream_id is required')
	}

	override_thread_id := cmd.correlation.thread_id
	override_cwd := cmd.working_dir

	// Prefer an explicit thread binding when the caller is resuming a known thread.
	thread_id := if override_thread_id != '' {
		rt.bind_stream_to_thread(override_thread_id, stream_id)
	} else {
		rt.begin_turn_stream(stream_id)
	}
	if thread_id != '' {
		if override_thread_id != '' {
			log.info('[codex] 📌 deterministic bind: explicit thread=${thread_id} → stream=${stream_id}')
		} else {
			log.info('[codex] 📌 deterministic bind: thread=${thread_id} → stream=${stream_id}')
		}
	}

	// Map stream_id to message_id for gateway routing
	message_id := cmd.response_message_id
	if message_id != '' {
		rt.add_stream_target(stream_id, codex.CodexTarget{
			platform:   'feishu'
			message_id: message_id
		})
	}

	// Build JSON-RPC request for turn/start
	id := rt.next_rpc_id()
	rt.remember_pending_rpc(id, codex.PendingRpc{
		instance:   instance
		method:     'turn/start'
		stream_id:  stream_id
		message_id: cmd.response_message_id
	})
	app.providers.codex.update(instance, rt)

	if thread_id == '' {
		return error('no active codex thread available for turn')
	}

	// Create params using threadId and input array as per protocol
	escaped_prompt := cmd.prompt.replace('"', '\\"').replace('\n', '\\n')

	// sandboxPolicy object
	// turn/start sandboxPolicy.type expects camelCase
	sandbox_type_wire := codex.SandboxMode.format(cfg.sandbox, true)
	mut sandbox_policy := '{"type":"${sandbox_type_wire}"'
	cwd := if override_cwd != '' { override_cwd } else { cfg.cwd }

	if cwd != '' {
		sandbox_policy += ',"writableRoots":["${cwd}"]'
	}
	sandbox_policy += ',"networkAccess":true}'

	mut params := '"threadId":"${thread_id}",'
	params += '"input":[{"type":"text","text":"${escaped_prompt}"}],'
	params += '"effort":"${cfg.effort}",'
	params += '"model":"${cfg.model}",'
	params += '"approvalPolicy":"${cfg.approval_policy}",'
	params += '"sandboxPolicy":${sandbox_policy}'

	if cwd != '' {
		params += ',"cwd":"${cwd}"'
	}

	// Add session info as sessionReference
	if cmd.correlation.session_key != '' {
		params += ',"sessionReference":"${cmd.correlation.session_key}"'
	}

	params = '{${params}}'

	req_msg := codex.RpcFrame.request('turn/start', id, params)
	log.info('[codex] 🧭 rpc route instance=${codex.ProviderRuntime.normalize_instance(instance)} method=turn/start url=${rt.ws_url} thread_id=${thread_id} stream_id=${stream_id} cwd=${cwd}')
	log.info('[codex]    → turn/start rpc: ${req_msg}')
	codex.RpcDebug.log('rpc.send.params.turn/start', params)

	// Send to websocket
	req := upstream.UpstreamSendRequest{
		provider: 'codex'
		instance: instance
		text:     req_msg
	}
	app.websocket_upstream_send(req)!
	app.emit('codex.turn.requested', {
		'stream_id': stream_id
		'rpc_id':    '${id}'
	})
}

fn (mut app App) codex_queue_error_dispatch(instance string, stream_id_ string, raw_payload string) {
	mut stream_id := stream_id_
	if stream_id == '' {
		// Deterministic recovery from pending RPCs still valid as they are explicitly tied
		stream_id = app.codex_pending_stream_id(instance)
		if stream_id == '' {
			stream_id = app.codex_get_active_stream_id_for_instance(instance)
		}
	}

	if stream_id == '' {
		log.error('[codex] ❌ CRITICAL: cannot queue error, stream_id is still empty after all recovery attempts. Payload: ${raw_payload}')
		return
	}

	log.info('[codex] ⚡️ queuing error for stream_id=${stream_id}')
	should_schedule_flush := app.codex_queue_error_burst(instance, stream_id, raw_payload)
	if !should_schedule_flush {
		return
	}

	// Wait 500ms to collect all simultaneous errors (e.g. status change + rpc error)
	spawn fn (mut app App, instance_name string, s_id string) {
		time.sleep(500 * time.millisecond)
		app.codex_flush_error_burst(instance_name, s_id)
	}(mut app, codex.ProviderRuntime.normalize_instance(instance), stream_id)
}

fn (mut app App) codex_flush_error_burst(instance string, stream_id string) {
	errors := app.codex_take_error_burst(instance, stream_id)

	if errors.len == 0 {
		return
	}

	// Pick the first error as base properties, but we'll send all error details to PHP
	log.info('[codex] 💥 flushing error burst for stream_id=${stream_id} (${errors.len} messages)')

	pending := codex.PendingRpc{
		instance:  codex.ProviderRuntime.normalize_instance(instance)
		method:    'codex.error_burst'
		stream_id: stream_id
	}

	// Join all error details as a JSON array
	result := json.encode(errors)
	// Use the first raw as original message for any metadata extraction
	app.dispatch_codex_rpc_response(instance, pending, result, true, errors[0])
}
