module main

import log
import codex

// ── Provider lifecycle callbacks ────────────────────────────────────────

fn (mut app App) codex_provider_enabled() bool {
	return app.provider_enabled('codex')
}

fn (mut app App) codex_provider_pull_url(instance string) !string {
	rt := app.codex_runtime_ensure_instance(instance)
	return rt.pull_url()
}

fn (mut app App) codex_provider_on_connecting(instance string) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	log.info('[codex] connecting instance=${rt.instance} to ${rt.url} ...')
	rt.note_connecting()
	app.providers.codex.update(instance, rt)
}

fn (mut app App) codex_provider_on_connected(instance string, ws_url string) {
	log.info('[codex] ✅ connected instance=${codex.ProviderRuntime.normalize_instance(instance)} to ${ws_url}')
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.note_connected(ws_url)
	app.providers.codex.update(instance, rt)
}

fn (mut app App) codex_provider_on_disconnected(instance string, reason string) {
	log.error('[codex] ❌ disconnected instance=${codex.ProviderRuntime.normalize_instance(instance)}: ${reason}')
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.note_disconnected(reason)
	app.providers.codex.update(instance, rt)

	// Connections will be cleaned up by PHP as needed or timed out
}

fn (mut app App) codex_provider_reconnect_delay_ms(instance string) int {
	rt := app.codex_runtime_ensure_instance(instance)
	return rt.reconnect_delay_ms_value()
}

fn (mut app App) codex_runtime_config_snapshot(instance string) codex.AdminConfigSnapshot {
	return app.providers.codex.snapshot(instance).config_snapshot()
}

fn (mut app App) codex_runtime_state_view(instance string) codex.RuntimeStateView {
	return app.providers.codex.snapshot(instance).state_view()
}

// ── Admin snapshot ──────────────────────────────────────────────────────

fn (mut app App) admin_codex_snapshot() codex.AdminRuntimeSnapshot {
	rt := app.codex_runtime_state_view('main')
	return codex.AdminRuntimeSnapshot{
		enabled:            app.codex_provider_enabled()
		connected:          rt.connected
		initialized:        rt.initialized
		ws_url:             rt.ws_url
		thread_id:          rt.thread_id
		active_turns:       0
		last_connect_at:    rt.last_connect_at
		last_disconnect_at: rt.last_disconnect_at
		last_error:         rt.last_error
		connect_attempts:   rt.connect_attempts
		connect_successes:  rt.connect_successes
		received_frames:    rt.received_frames
		config:             app.codex_runtime_config_snapshot('main')
	}
}
