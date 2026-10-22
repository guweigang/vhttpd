module main

import command
import json2 as json
import log
import time
import net.websocket
import codex

struct CodexPreparedTurn {
	config       codex.AdminConfigSnapshot
	ws_url       string
	thread_id    string
	id           int
	registration ?codex.RpcRegistration
	connection   ?&websocket.Client
	failure      string
}

// Validate and publish the turn's routing and pending RPC as one transition.
// Request encoding, logging and WebSocket I/O happen after the owner unlocks.
fn (mut app App) codex_prepare_turn(cmd command.NormalizedCommand) CodexPreparedTurn {
	instance := codex.ProviderRuntime.normalize_instance(cmd.instance)
	mut state := &app.providers.codex
	return app.providers.codex_runtime_mutate[CodexPreparedTurn](instance, fn [cmd, instance, mut state] (mut rt codex.ProviderRuntime) CodexPreparedTurn {
		if !rt.is_connected() {
			return CodexPreparedTurn{ failure: 'codex provider not connected' }
		}
		if !rt.is_initialized() {
			return CodexPreparedTurn{ failure: 'codex provider not initialized' }
		}
		stream_id := cmd.correlation.stream_id
		if stream_id == '' { return CodexPreparedTurn{ failure: 'codex stream_id is required' } }
		thread_id := if cmd.correlation.thread_id != '' {
			cmd.correlation.thread_id
		} else {
			rt.current_thread_id()
		}
		if thread_id == '' {
			return CodexPreparedTurn{ failure: 'no active codex thread available for turn' }
		}
		if cmd.correlation.thread_id != '' {
			rt.bind_stream_to_thread(thread_id, stream_id)
		} else {
			rt.begin_turn_stream(stream_id)
		}
		if cmd.response_message_id != '' {
			rt.add_stream_target(stream_id, codex.CodexTarget{ platform: 'feishu', message_id: cmd.response_message_id })
		}
		registration := state.register_rpc_unlocked(instance, mut rt, codex.PendingRpc{ instance: instance, method: 'turn/start', stream_id: stream_id, message_id: cmd.response_message_id })
		return CodexPreparedTurn{ config: rt.config_snapshot(), ws_url: rt.ws_url, thread_id: thread_id, id: registration.id, registration: registration, connection: rt.connection() }
	})
}

// A prepared turn owns pending-send cleanup and borrows exactly the connection
// captured with its registration; it cannot select a newer connection on send.
fn (prepared CodexPreparedTurn) send(payload string) ! {
	registration := prepared.registration or { return error('codex pending registration unavailable') }
	mut client := prepared.connection or {
		registration.cancel()
		return error('codex provider not connected')
	}
	codex_write_registered_rpc(registration, mut client, payload)!
}

// ── Turn Management ─────────────────────────────────────────────────────

fn (mut app App) codex_start_turn_normalized(cmd command.NormalizedCommand) ! {
	log.info('[codex] 🚀 codex_start_turn stream_id=${cmd.correlation.stream_id} task_type=${cmd.task_type} prompt=${cmd.prompt}')
	instance := codex.ProviderRuntime.normalize_instance(cmd.instance)
	prepared := app.codex_prepare_turn(cmd)
	if prepared.failure != '' { return error(prepared.failure) }
	cfg := prepared.config
	stream_id := cmd.correlation.stream_id
	override_cwd := cmd.working_dir
	thread_id := prepared.thread_id
	id := prepared.id
	log.info('[codex] 📌 turn bind: thread=${thread_id} → stream=${stream_id}')

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
	log.info('[codex] 🧭 rpc route instance=${codex.ProviderRuntime.normalize_instance(instance)} method=turn/start url=${prepared.ws_url} thread_id=${thread_id} stream_id=${stream_id} cwd=${cwd}')
	log.info('[codex]    → turn/start rpc: ${req_msg}')
	codex.RpcDebug.log('rpc.send.params.turn/start', params)

	prepared.send(req_msg)!
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
	job := app.codex_queue_error_burst(instance, stream_id, raw_payload) or { return }
	spawn fn (mut app App, job &codex.ErrorBurstJob) {
		defer { job.finish() }
		if !job.wait(500 * time.millisecond) { return }
		app.codex_flush_error_burst(job)
	}(mut app, job)
}

fn (mut app App) codex_flush_error_burst(job &codex.ErrorBurstJob) {
	errors := job.take()
	instance := job.instance
	stream_id := job.stream_id

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
	result := json.encode(errors, escape_unicode: true, time_as_unix: true)
	// Use the first raw as original message for any metadata extraction
	app.dispatch_codex_rpc_response(instance, pending, result, true, errors[0])
}
