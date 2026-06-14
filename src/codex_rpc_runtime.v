module main

import log
import codex

// ── JSON-RPC encode / decode ────────────────────────────────────────────
// Codex app-server wire format: JSON-RPC 2.0 with "jsonrpc":"2.0" OMITTED.

fn (mut app App) codex_next_rpc_id(instance string) int {
	mut rt := app.codex_runtime_ensure_instance(instance)
	id := rt.next_rpc_id()
	app.providers.codex.update(instance, rt)
	return id
}

// ── WebSocket text message handler ──────────────────────────────────────

fn (mut app App) codex_provider_handle_text_message(instance string, raw string) {
	frame_count := app.codex_note_frame_received(instance)

	preview := if raw.len > 200 { raw[..200] + '...' } else { raw }
	log.info('[codex] 📩 instance=${codex.ProviderRuntime.normalize_instance(instance)} frame #${frame_count}: ${preview}')
	codex.RpcDebug.log('frame.raw', raw)

	classification := codex.RpcFrame.classify(raw)
	log.info('[codex] 🔎 instance=${codex.ProviderRuntime.normalize_instance(instance)} frame #${frame_count} ${codex.RpcFrame.summary(raw,
		classification)}')

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
