module main

import log
import net.websocket as net_ws
import time
import upstream
import codex

// ── Initialize handshake ────────────────────────────────────────────────
// Must be called right after WebSocket connect, before any other RPC.

fn (mut app App) codex_send_initialize(instance string, mut conn net_ws.Client) ! {
	log.info('[codex] 🤝 sending initialize instance=${codex.ProviderRuntime.normalize_instance(instance)} ...')
	id := app.codex_next_rpc_id(instance)
	params := '{"clientInfo":{"name":"codex_vhttpd","title":"vhttpd Codex Integration","version":"0.1.0"},"capabilities":{"experimentalApi":true}}'
	msg := codex.RpcFrame.request('initialize', id, params)
	log.info('[codex]    → ${msg}')
	codex.RpcDebug.log('rpc.send.params.initialize', params)
	conn.write_string(msg)!
	app.emit('codex.rpc.sent', {
		'method':   'initialize'
		'id':       '${id}'
		'instance': codex.ProviderRuntime.normalize_instance(instance)
	})
}

fn (mut app App) codex_send_initialized(instance string, mut conn net_ws.Client) ! {
	log.info('[codex] 🤝 sending initialized notification instance=${codex.ProviderRuntime.normalize_instance(instance)} ...')
	msg := codex.RpcFrame.notification('initialized', '{}')
	conn.write_string(msg)!
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.mark_initialized()
	app.providers.codex.update(instance, rt)
	app.emit('codex.rpc.sent', {
		'method':   'initialized'
		'instance': codex.ProviderRuntime.normalize_instance(instance)
	})
}

fn (mut app App) codex_send_thread_start(instance string, mut conn net_ws.Client) ! {
	cfg := app.providers.codex.snapshot(instance)
	rt := app.providers.codex.snapshot(instance)
	log.info('[codex] 🤝 sending thread/start instance=${codex.ProviderRuntime.normalize_instance(instance)} url=${rt.ws_url} cwd=${cfg.cwd} ...')
	id := app.codex_next_rpc_id(instance)
	// thread/start expects kebab-case for top-level sandbox field
	sandbox_wire := codex.SandboxMode.format(cfg.sandbox, false)
	params := '{"model":"${cfg.model}","cwd":"${cfg.cwd}","approvalPolicy":"${cfg.approval_policy}","sandbox":"${sandbox_wire}"}'
	msg := codex.RpcFrame.request('thread/start', id, params)
	log.info('[codex]    → ${msg}')
	codex.RpcDebug.log('rpc.send.params.thread/start', params)
	conn.write_string(msg)!
	app.emit('codex.rpc.sent', {
		'method':   'thread/start'
		'id':       '${id}'
		'instance': codex.ProviderRuntime.normalize_instance(instance)
	})
}

// Called from run_websocket_upstream_provider after connect + on_connected.
// Sends initialize request, waits briefly for response, then sends initialized.
fn (mut app App) codex_post_connect_handshake(instance string, mut conn net_ws.Client) {
	app.codex_send_initialize(instance, mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase':    'initialize'
			'instance': codex.ProviderRuntime.normalize_instance(instance)
			'error':    '${err}'
		})
		return
	}
	// Small delay to allow the initialize response to arrive via the message callback
	time.sleep(200 * time.millisecond)
	app.codex_send_initialized(instance, mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase':    'initialized'
			'instance': codex.ProviderRuntime.normalize_instance(instance)
			'error':    '${err}'
		})
		return
	}

	// Wait a bit and send thread/start to have an active thread
	time.sleep(200 * time.millisecond)
	app.codex_send_thread_start(instance, mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase':    'thread/start'
			'instance': codex.ProviderRuntime.normalize_instance(instance)
			'error':    '${err}'
		})
		return
	}

	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.attach_connection(conn)
	app.providers.codex.update(instance, rt)

	app.emit('codex.handshake.completed', {
		'phase':    'initialized'
		'instance': codex.ProviderRuntime.normalize_instance(instance)
	})
}

// ── Generic WebSocket Upstream Provider Implementation ──────────────────

fn (mut app App) codex_provider_send(req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	instance := codex.ProviderRuntime.normalize_instance(req.instance)
	rt := app.providers.codex.snapshot(instance)
	mut conn := rt.connection()
	connected := rt.is_connected()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	conn.write_string(req.text)!

	return upstream.UpstreamSendResult{
		ok:         true
		provider:   websocket_upstream_provider_codex
		instance:   instance
		message_id: 'codex-rpc-${time.now().unix_micro()}'
	}
}

fn (mut app App) codex_provider_update(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	// Codex as a WebSocket provider doesn't really have "message updates" in the same sense as Feishu,
	// but we might use it to send follow-up notifications.
	res := app.codex_provider_send(req)!
	return upstream.UpstreamUpdateResult{
		ok:         res.ok
		provider:   res.provider
		instance:   res.instance
		message_id: res.message_id
	}
}
