module main

import log
import time
import codex

fn (mut app App) codex_handle_server_request(instance string, cls codex.RpcClassification, raw string) {
	log.info('[codex] 🙋 instance=${codex.ProviderRuntime.normalize_instance(instance)} server request: method=${cls.method} id=${cls.id_raw}')
	codex.RpcDebug.log('server_request.raw.${cls.method}', raw)

	detected_thread_id := codex.RpcField.string(raw, 'threadId')
	mut target_stream_id := ''
	if detected_thread_id != '' {
		target_stream_id = app.codex_repair_thread_stream_binding(instance, detected_thread_id)
		if target_stream_id != '' {
			log.info('[codex] 🔗 request bind: thread=${detected_thread_id} → stream=${target_stream_id}')
		}
	}
	active_stream_id := app.codex_get_active_stream_id_for_instance(instance)
	pending_stream_id := app.codex_pending_stream_id(instance)
	mut stream_id := target_stream_id
	if stream_id == '' {
		stream_id = active_stream_id
	}
	if stream_id == '' {
		stream_id = pending_stream_id
	}

	app.emit('codex.server_request', {
		'method':    cls.method
		'id':        cls.id_raw
		'instance':  codex.ProviderRuntime.normalize_instance(instance)
		'thread_id': detected_thread_id
		'stream_id': stream_id
	})

	if !app.has_websocket_upstream_logic_executor() {
		return
	}

	log.info('[codex] 🚚 request dispatch instance=${codex.ProviderRuntime.normalize_instance(instance)} method=${cls.method} chosen_stream=${stream_id} source=${if target_stream_id != '' {
		'thread_binding'
	} else if active_stream_id != '' {
		'active_stream'
	} else if pending_stream_id != '' {
		'pending_stream'
	} else {
		'none'
	}}')
	req := app.kernel_websocket_upstream_dispatch_request('codex-request-${time.now().unix_milli()}',
		'codex', codex.ProviderRuntime.normalize_instance(instance), stream_id,
		'codex.server_request', '', '', '', raw, time.now().unix(), map[string]string{})
	outcome := app.kernel_dispatch_websocket_upstream_handled(req) or {
		log.error('[codex] ❌ failed to dispatch codex server request: ${err}')
		return
	}
	resp := outcome.response
	if resp.error != '' {
		log.error('[codex] ❌ codex server request worker error: ${resp.error}')
	}
	log.info('[codex] 🧾 codex server request result: method=${cls.method} handled=${resp.handled} commands=${resp.commands.len} error=${resp.error}')
	if resp.commands.len > 0 && outcome.command_error != '' {
		log.error('[codex] ❌ codex server request command execution error: ${outcome.command_error}')
	}
}
