module main

import log
import time
import codex

fn (mut app App) codex_handle_response(instance string, cls codex.RpcClassification, raw string) {
	log.info('[codex] 📨 instance=${codex.ProviderRuntime.normalize_instance(instance)} response id=${cls.id_raw} has_error=${cls.has_error}')
	codex.RpcDebug.log('response.raw', raw)

	// Check for pending RPCs FIRST so we know the stream_id
	id := cls.id_raw.int()
	pending, _ := app.codex_take_pending_rpc(instance, id)
	log.info('[codex] 🧩 response match instance=${codex.ProviderRuntime.normalize_instance(instance)} id=${cls.id_raw} pending_method=${pending.method} pending_stream=${pending.stream_id} pending_message=${pending.message_id}')

	if cls.has_error {
		if pending.stream_id != '' {
			app.codex_clear_read_fallback(instance, pending.stream_id)
		}
		error_msg := codex.RpcField.string(raw, 'message')
		app.emit('codex.rpc.error', {
			'id':       cls.id_raw
			'error':    error_msg
			'instance': codex.ProviderRuntime.normalize_instance(instance)
		})

		// If we have a pending rpc with a stream_id, aggregate this error
		if pending.stream_id != '' {
			app.codex_queue_error_dispatch(instance, pending.stream_id, raw)
		} else {
			// Fallback: use active stream
			app.codex_queue_error_dispatch(instance,
				app.codex_get_active_stream_id_for_instance(instance), raw)
		}
		return
	}
	// For thread/start response: extract thread id
	if raw.contains('"thread"') {
		// Use a more specific marker to avoid picking up the top-level "id"
		thread_marker := '"thread"'
		if thread_idx := raw.index(thread_marker) {
			thread_id := codex.RpcField.string(raw[thread_idx..], 'id')
			if thread_id != '' {
				app.codex_capture_thread_id(instance, thread_id)
				log.info('[codex]    ✅ thread_id extracted: ${thread_id}')
				app.emit('codex.thread.created', {
					'thread_id': thread_id
					'instance':  codex.ProviderRuntime.normalize_instance(instance)
				})
			}
		}
	}
	// For turn/start response: extract turn id
	if raw.contains('"turn"') {
		// Avoid top-level "id" (RPC ID)
		if turn_idx := raw.index('"turn"') {
			turn_id := codex.RpcField.string(raw[turn_idx..], 'id')
			if turn_id != '' {
				log.info('[codex]    ✅ turn_id extracted: ${turn_id}')
				app.emit('codex.turn.response', {
					'turn_id':  turn_id
					'instance': codex.ProviderRuntime.normalize_instance(instance)
				})
			}
		}
	}

	if pending.method != '' {
		// Route result back to PHP
		result_raw := if cls.has_error {
			codex.RpcField.raw(raw, 'error')
		} else {
			codex.RpcField.raw(raw, 'result')
		}
		app.dispatch_codex_rpc_response(instance, pending, result_raw, cls.has_error, raw)
		if pending.method == 'thread/read' {
			app.codex_clear_read_fallback(instance, pending.stream_id)
		}
	}
}

fn (mut app App) dispatch_codex_rpc_response(instance string, pending codex.PendingRpc, result_raw string, has_error bool, raw string) {
	log.info('[codex] 🏁 dispatch_codex_rpc_response instance=${codex.ProviderRuntime.normalize_instance(instance)} method=${pending.method} stream_id=${pending.stream_id} error=${has_error}')
	codex.RpcDebug.log('rpc.dispatch.raw_response', raw)
	codex.RpcDebug.log('rpc.dispatch.result_raw', result_raw)
	if !app.has_websocket_upstream_logic_executor() {
		log.warn('[codex] ⚠️ websocket_upstream logic executor unavailable, skipping dispatch')
		return
	}

	req := app.kernel_websocket_upstream_dispatch_request('codex-rpc-${time.now().unix_milli()}',
		'codex', codex.ProviderRuntime.normalize_instance(instance), pending.stream_id,
		'codex.rpc.response', pending.message_id, pending.stream_id, 'stream_id',
		'{"method":"${pending.method}","result":${result_raw},"has_error":${has_error},"raw_response":${raw}}',
		time.now().unix(), map[string]string{})

	outcome := app.kernel_dispatch_websocket_upstream_handled(req) or {
		log.error('[codex] ❌ failed to dispatch websocket_upstream: ${err}')
		return
	}
	resp := outcome.response

	if resp.commands.len > 0 {
		log.info('[codex]    ✅ worker returned ${resp.commands.len} commands')
		if outcome.command_error != '' {
			log.error('[codex]    ❌ command execution error: ${outcome.command_error}')
		}
	}
}
