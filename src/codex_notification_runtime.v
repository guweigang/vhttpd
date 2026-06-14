module main

import log
import time
import codex

// ── Notification routing ────────────────────────────────────────────────

fn (mut app App) codex_handle_notification(instance string, method string, raw string) {
	// 1. Transparent logging
	log.info('[codex] 📢 instance=${codex.ProviderRuntime.normalize_instance(instance)} notification: ${method}')
	codex.RpcDebug.log('notification.raw.${method}', raw)

	// 2. Minimal gateway-level state sync & Mapping Lookups
	detected_thread_id := codex.RpcField.string(raw, 'threadId')

	mut target_stream_id := ''
	if detected_thread_id != '' {
		target_stream_id = app.codex_repair_thread_stream_binding(instance, detected_thread_id)
		if target_stream_id != '' {
			log.info('[codex] 🔗 reactive bind: thread=${detected_thread_id} → stream=${target_stream_id}')
		}
	}
	active_stream_id := app.codex_get_active_stream_id_for_instance(instance)
	pending_stream_id := app.codex_pending_stream_id(instance)
	log.info('[codex] 🧭 notif route instance=${codex.ProviderRuntime.normalize_instance(instance)} method=${method} thread=${detected_thread_id} target_stream=${target_stream_id} active_stream=${active_stream_id} pending_stream=${pending_stream_id}')

	// 🚨 航空级强化：拦截所有异步错误通知并聚合，防止抢跑或互相覆盖
	is_system_error := method == 'thread/status/changed' && raw.contains('"systemError"')
	is_generic_error := method == 'error'
	if is_system_error || is_generic_error {
		if target_stream_id != '' {
			app.codex_clear_read_fallback(instance, target_stream_id)
		}
		mut t_id := target_stream_id
		if t_id == '' {
			t_id = app.codex_get_active_stream_id_for_instance(instance)
			log.warn('[codex] ⚠️ fallback to active_stream_id=${t_id} for error type=${method}')
		} else {
			log.error('[codex] 🚨 DETERMINISTIC ERROR: type=${method} thread=${detected_thread_id} → stream=${t_id}')
		}
		app.codex_queue_error_dispatch(instance, t_id, raw)
		return
	}

	match method {
		'thread/started' {
			if raw.contains('"thread"') {
				if idx := raw.index('"thread"') {
					thread_id := codex.RpcField.string(raw[idx..], 'id')
					if thread_id != '' {
						if app.codex_ensure_thread_id(instance, thread_id) {
							log.info('[codex]    ✅ thread_id sync: ${thread_id}')
						}
					}
				}
			}
		}
		'item/agentMessage/delta' {
			if target_stream_id != '' {
				app.codex_clear_read_fallback(instance, target_stream_id)
			}
			// Keep delta delivery on the PHP side for now so a single renderer owns
			// buffering and flush. Native patching here races with PHP patch/flush and
			// can duplicate content or orphan Feishu buffers.
		}
		else {}
	}

	if target_stream_id != '' && (method == 'thread/realtime/itemAdded' || method.contains('/delta')
		|| method.ends_with('Delta')) {
		app.codex_clear_read_fallback(instance, target_stream_id)
	}

	if method == 'turn/completed' || method == 'turn/started' || method == 'item/completed'
		|| method == 'rawResponseItem/completed' {
		if target_stream_id != '' {
			app.codex_clear_read_fallback(instance, target_stream_id)
		}
	}
	if method == 'thread/status/changed' {
		status_type := codex.RpcField.string(raw, 'type').to_lower()
		if (status_type == 'idle' || status_type == 'completed' || status_type == 'error')
			&& target_stream_id != '' {
			app.codex_clear_read_fallback(instance, target_stream_id)
		}
	}

	// 3. Dispatch raw payload to business logic executor.
	if app.has_websocket_upstream_logic_executor() {
		mut stream_id := target_stream_id
		if stream_id == '' {
			stream_id = active_stream_id
		}
		if stream_id == '' {
			stream_id = pending_stream_id
		}
		log.info('[codex] 🚚 notif dispatch instance=${codex.ProviderRuntime.normalize_instance(instance)} method=${method} chosen_stream=${stream_id} source=${if target_stream_id != '' {
			'thread_binding'
		} else if active_stream_id != '' {
			'active_stream'
		} else if pending_stream_id != '' {
			'pending_stream'
		} else {
			'none'
		}}')

		req := app.kernel_websocket_upstream_dispatch_request('codex-notif-${time.now().unix_milli()}',
			'codex', codex.ProviderRuntime.normalize_instance(instance), stream_id,
			'codex.notification', '', '', '', raw, time.now().unix(), map[string]string{})
		outcome := app.kernel_dispatch_websocket_upstream_handled(req) or {
			log.error('[codex] ❌ failed to dispatch codex notification: ${err}')
			return
		}
		resp := outcome.response
		if resp.error != '' {
			log.error('[codex] ❌ codex notification worker error: ${resp.error}')
		}
		log.info('[codex] 🧾 codex notification result: method=${method} handled=${resp.handled} commands=${resp.commands.len} error=${resp.error}')
		if resp.commands.len > 0 {
			if outcome.command_error != '' {
				log.error('[codex] ❌ codex notification command execution error: ${outcome.command_error}')
			}
		}
	}
}
