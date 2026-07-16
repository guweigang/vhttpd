module main

import log
import codex

// ── Provider lifecycle callbacks ────────────────────────────────────────

fn (hub ProviderRuntimeHub) codex_provider_enabled(db_transport_enabled bool) bool {
	return hub.provider_enabled('codex', hub.provider_bootstrap_enabled('codex',
		db_transport_enabled))
}

fn (mut app App) codex_provider_enabled() bool {
	return app.providers.codex_provider_enabled(app.transport.db.enabled)
}

fn (mut app App) codex_provider_pull_url(instance string) !string {
	rt := app.codex_runtime_ensure_instance(instance)
	return rt.pull_url()
}

fn (mut hub ProviderRuntimeHub) codex_provider_reconnect_delay_ms(instance string) int {
	rt := hub.codex_runtime_ensure_instance(instance)
	return rt.reconnect_delay_ms_value()
}

fn (mut app App) codex_provider_reconnect_delay_ms(instance string) int {
	return app.providers.codex_provider_reconnect_delay_ms(instance)
}

fn (mut hub ProviderRuntimeHub) codex_provider_on_connecting(instance string) {
	mut rt := hub.codex_runtime_ensure_instance(instance)
	log.info('[codex] connecting instance=${rt.instance} to ${rt.url} ...')
	rt.note_connecting()
	hub.codex.update(instance, rt)
}

fn (mut app App) codex_provider_on_connecting(instance string) {
	app.providers.codex_provider_on_connecting(instance)
}

fn (mut hub ProviderRuntimeHub) codex_provider_on_connected(instance string, ws_url string) {
	log.info('[codex] ✅ connected instance=${codex.ProviderRuntime.normalize_instance(instance)} to ${ws_url}')
	mut rt := hub.codex_runtime_ensure_instance(instance)
	rt.note_connected(ws_url)
	hub.codex.update(instance, rt)
}

fn (mut app App) codex_provider_on_connected(instance string, ws_url string) {
	app.providers.codex_provider_on_connected(instance, ws_url)
}

fn (mut hub ProviderRuntimeHub) codex_provider_on_disconnected(instance string, reason string) {
	log.error('[codex] ❌ disconnected instance=${codex.ProviderRuntime.normalize_instance(instance)}: ${reason}')
	mut rt := hub.codex_runtime_ensure_instance(instance)
	rt.note_disconnected(reason)
	hub.codex.update(instance, rt)

	// Connections will be cleaned up by PHP as needed or timed out
}

fn (mut app App) codex_provider_on_disconnected(instance string, reason string) {
	app.providers.codex_provider_on_disconnected(instance, reason)
}

fn (mut hub ProviderRuntimeHub) codex_runtime_config_snapshot(instance string) codex.AdminConfigSnapshot {
	return hub.codex.snapshot(instance).config_snapshot()
}

fn (mut app App) codex_runtime_config_snapshot(instance string) codex.AdminConfigSnapshot {
	return app.providers.codex_runtime_config_snapshot(instance)
}

fn (mut hub ProviderRuntimeHub) codex_runtime_state_view(instance string) codex.RuntimeStateView {
	return hub.codex.snapshot(instance).state_view()
}

fn (mut app App) codex_runtime_state_view(instance string) codex.RuntimeStateView {
	return app.providers.codex_runtime_state_view(instance)
}

// ── Admin snapshot ──────────────────────────────────────────────────────

fn (mut hub ProviderRuntimeHub) admin_codex_snapshot(db_transport_enabled bool) codex.AdminRuntimeSnapshot {
	rt := hub.codex_runtime_state_view('main')
	return codex.AdminRuntimeSnapshot{
		enabled:            hub.codex_provider_enabled(db_transport_enabled)
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
		config:             hub.codex_runtime_config_snapshot('main')
	}
}

fn (mut app App) admin_codex_snapshot() codex.AdminRuntimeSnapshot {
	return app.providers.admin_codex_snapshot(app.transport.db.enabled)
}
