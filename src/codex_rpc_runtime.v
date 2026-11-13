module main

import log
import codex
import time

// ── JSON-RPC encode / decode ────────────────────────────────────────────
// Codex app-server wire format: JSON-RPC 2.0 with "jsonrpc":"2.0" OMITTED.

fn (mut app App) codex_next_rpc_id(instance string) int {
	return app.providers.codex_runtime_mutate[int](instance, fn (mut rt codex.ProviderRuntime) int {
		return rt.next_rpc_id()
	})
}

// ── WebSocket text message handler ──────────────────────────────────────

fn (mut app App) codex_provider_handle_text_message(instance string, raw string) {
	frame_count := app.codex_note_frame_received(instance)

	preview := if raw.len > 200 { raw[..200] + '...' } else { raw }
	log.info('[codex] 📩 instance=${codex.ProviderRuntime.normalize_instance(instance)} frame #${frame_count}: ${preview}')
	codex.RpcDebug.log('frame.raw', raw)

	classification := codex.RpcFrame.classify(raw)
	log.info('[codex] 🔎 instance=${codex.ProviderRuntime.normalize_instance(instance)} frame #${frame_count} ${codex.RpcFrame.summary(raw, classification)}')

	if !classification.is_response && !classification.is_notification && !classification.is_request {
		app.providers.codex_runtime_mutate[bool](instance, fn (mut rt codex.ProviderRuntime) bool {
			rt.protocol.failed('decode', 'invalid_envelope', 'protocol_error')
			return true
		})
		return
	}
	if app.providers.codex.snapshot(instance).application_messages && !classification.is_response {
		event_type := if classification.is_request { 'codex.server_request' } else { 'codex.notification' }
		req := app.kernel_websocket_upstream_dispatch_request('codex-${time.now().unix_micro()}',
			'codex', codex.ProviderRuntime.normalize_instance(instance), '', event_type,
			'', '', '', raw, time.now().unix(), map[string]string{})
		app.kernel_dispatch_websocket_upstream_handled(req) or {
			log.error('[codex] application dispatch failed: ${err}')
		}
		return
	}
	if classification.is_response {
		app.codex_handle_response(instance, classification, raw)
		return
	}
	if classification.is_notification {
		app.codex_handle_notification(instance, classification.method, raw)
		return
	}
	if classification.is_request {
		app.codex_handle_server_request(instance, classification, raw)
		return
	}
	log.warn('[codex] ⚠️ instance=${codex.ProviderRuntime.normalize_instance(instance)} frame #${frame_count} unclassified')
}
