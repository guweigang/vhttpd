module main

import log
import codex

fn (mut app App) codex_send_internal_thread_resume(instance string, thread_id string) ! {
	if thread_id.trim_space() == '' {
		return
	}
	resolved_instance := codex.ProviderRuntime.normalize_instance(instance)
	id := app.codex_next_rpc_id(resolved_instance)
	app.codex_remember_pending_rpc(resolved_instance, id, codex.PendingRpc{})
	rt := app.providers.codex.snapshot(resolved_instance)
	mut conn := rt.connection()
	connected := rt.is_connected()
	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}
	params := '{"threadId":"${thread_id}","persistExtendedHistory":true}'
	msg := codex.RpcFrame.request('thread/resume', id, params)
	log.info('[codex] 🔄 internal thread/resume instance=${resolved_instance} thread_id=${thread_id} rpc_id=${id}')
	log.info('[codex] 📤 sending internal rpc: ${msg}')
	codex.RpcDebug.log('rpc.send.params.thread/resume', params)
	conn.write_string(msg)!
}

fn (mut app App) codex_send_rpc(instance string, method string, params string, stream_id string, message_id string) !int {
	resolved_instance := codex.ProviderRuntime.normalize_instance(instance)
	explicit_thread_id := codex.RpcField.thread_id(params)
	current_thread_id := app.providers.codex.snapshot(resolved_instance).current_thread_id()
	if method == 'turn/start' && explicit_thread_id != '' && current_thread_id != ''
		&& explicit_thread_id != current_thread_id {
		app.codex_send_internal_thread_resume(resolved_instance, explicit_thread_id)!
	}
	id := app.codex_next_rpc_id(resolved_instance)
	app.codex_remember_pending_rpc(resolved_instance, id, codex.PendingRpc{
		instance:   resolved_instance
		method:     method
		stream_id:  stream_id
		message_id: message_id
	})

	// 🚨 航空级堵漏：确保 RPC 调用也能建立物理绑定
	if stream_id != '' {
		bound_thread_id := if explicit_thread_id != '' {
			app.codex_bind_stream_to_thread(resolved_instance, explicit_thread_id, stream_id)
		} else {
			app.codex_bind_stream_to_current_thread(resolved_instance, stream_id)
		}
		if bound_thread_id != '' {
			if explicit_thread_id != '' {
				log.info('[codex] 📌 rpc bind: explicit thread=${bound_thread_id} → stream=${stream_id} (via ${method})')
			} else {
				log.info('[codex] 📌 rpc bind: thread=${bound_thread_id} → stream=${stream_id} (via ${method})')
			}
		}
	}

	rt := app.providers.codex.snapshot(resolved_instance)
	mut conn := rt.connection()
	connected := rt.is_connected()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	msg := codex.RpcFrame.request(method, id, params)
	thread_id := explicit_thread_id
	log.info('[codex] 🧭 rpc route instance=${resolved_instance} method=${method} url=${rt.ws_url} thread_id=${thread_id} stream_id=${stream_id}')
	log.info('[codex] 📤 sending custom rpc: ${msg}')
	codex.RpcDebug.log('rpc.send.params.${method}', params)
	conn.write_string(msg)!
	return id
}

fn (mut app App) codex_reply_rpc(instance string, id string, result string) ! {
	rt := app.providers.codex.snapshot(instance)
	mut conn := rt.connection()
	connected := rt.is_connected()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	msg := '{"id":${id},"result":${result}}'
	log.info('[codex] 📤 sending rpc reply: ${msg}')
	codex.RpcDebug.log('rpc.reply.result', result)
	conn.write_string(msg)!
}
