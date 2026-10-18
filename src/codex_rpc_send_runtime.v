module main

import log
import codex
import net.websocket as net_ws

struct CodexPreparedRpc {
	instance            string
	ws_url              string
	bound_thread_id     string
	resume_thread_id    string
	registration        ?codex.RpcRegistration
	resume_registration ?codex.RpcRegistration
	connection          ?&net_ws.Client
	failure             string
}

// Connection admission, optional resume and main registration, and routing
// publication share one state transition. No network I/O runs under the lock.
fn (mut hub ProviderRuntimeHub) codex_prepare_rpc(instance string, pending codex.PendingRpc, explicit_thread_id string) CodexPreparedRpc {
	resolved := codex.ProviderRuntime.normalize_instance(instance)
	mut state := &hub.codex
	return hub.codex_runtime_mutate[CodexPreparedRpc](resolved, fn [resolved, pending, explicit_thread_id, mut state] (mut rt codex.ProviderRuntime) CodexPreparedRpc {
		if !rt.is_connected() { return CodexPreparedRpc{ failure: 'codex provider not connected' } }
		connection := rt.connection() or { return CodexPreparedRpc{ failure: 'codex provider not connected' } }
		current_thread_id := rt.current_thread_id()
		mut resume := ?codex.RpcRegistration(none)
		mut resume_thread_id := ''
		if pending.method == 'turn/start' && explicit_thread_id != '' && current_thread_id != '' && explicit_thread_id != current_thread_id {
			resume = state.register_rpc_unlocked(resolved, mut rt, codex.PendingRpc{})
			resume_thread_id = explicit_thread_id
		}
		registration := state.register_rpc_unlocked(resolved, mut rt, pending)
		mut bound_thread_id := ''
		if pending.stream_id != '' {
			bound_thread_id = if explicit_thread_id != '' {
				rt.bind_stream_to_thread(explicit_thread_id, pending.stream_id)
			} else {
				rt.bind_stream_to_current_thread(pending.stream_id)
			}
		}
		return CodexPreparedRpc{ instance: resolved, ws_url: rt.ws_url, bound_thread_id: bound_thread_id, resume_thread_id: resume_thread_id, registration: registration, resume_registration: resume, connection: connection }
	})
}

// Each frame retains its own response registration only after a successful
// write. A retired registration cannot write on a captured old connection.
fn codex_write_registered_rpc(registration codex.RpcRegistration, mut connection net_ws.Client, payload string) ! {
	mut sent := false
	defer { if !sent { registration.cancel() } }
	if !registration.is_pending() { return error('codex pending registration retired') }
	connection.write_string(payload)!
	sent = true
}

fn (prepared CodexPreparedRpc) send(method string, params string) !int {
	if prepared.failure != '' { return error(prepared.failure) }
	registration := prepared.registration or { return error('codex pending registration unavailable') }
	mut sent := false
	mut resume_sent := false
	// Includes failure before either frame; a sent prelude keeps its own response registration.
	defer {
		if !sent { registration.cancel() }
		if !resume_sent {
			if resume := prepared.resume_registration { resume.cancel() }
		}
	}
	if !registration.is_pending() { return error('codex pending registration retired') }
	mut connection := prepared.connection or { return error('codex provider not connected') }
	if resume := prepared.resume_registration {
		resume_params := '{"threadId":"${prepared.resume_thread_id}","persistExtendedHistory":true}'
		log.info('[codex] 🔄 internal thread/resume instance=${prepared.instance} thread_id=${prepared.resume_thread_id} rpc_id=${resume.id}')
		codex_write_registered_rpc(resume, mut connection, codex.RpcFrame.request('thread/resume', resume.id, resume_params))!
		resume_sent = true
	}
	msg := codex.RpcFrame.request(method, registration.id, params)
	log.info('[codex] 🧭 rpc route instance=${prepared.instance} method=${method} url=${prepared.ws_url} thread_id=${prepared.bound_thread_id}')
	log.info('[codex] 📤 sending rpc: ${msg}')
	codex.RpcDebug.log('rpc.send.params.${method}', params)
	codex_write_registered_rpc(registration, mut connection, msg)!
	sent = true
	return registration.id
}

fn (mut app App) codex_send_internal_thread_resume(instance string, thread_id string) ! {
	if thread_id.trim_space() == '' { return }
	// Empty metadata keeps internal resume responses out of worker dispatch.
	prepared := app.providers.codex_prepare_rpc(instance, codex.PendingRpc{}, '')
	params := '{"threadId":"${thread_id}","persistExtendedHistory":true}'
	prepared.send('thread/resume', params)!
}

fn (mut app App) codex_send_rpc(instance string, method string, params string, stream_id string, message_id string) !int {
	resolved := codex.ProviderRuntime.normalize_instance(instance)
	prepared := app.providers.codex_prepare_rpc(resolved, codex.PendingRpc{ instance: resolved, method: method, stream_id: stream_id, message_id: message_id }, codex.RpcField.thread_id(params))
	return prepared.send(method, params)
}

fn (mut app App) codex_reply_rpc(instance string, id string, result string) ! {
	rt := app.providers.codex.snapshot(instance)
	mut conn := rt.connection() or { return error('codex provider not connected') }
	connected := rt.is_connected()

	if !connected {
		return error('codex provider not connected')
	}

	msg := '{"id":${id},"result":${result}}'
	log.info('[codex] 📤 sending rpc reply: ${msg}')
	codex.RpcDebug.log('rpc.reply.result', result)
	conn.write_string(msg)!
}
