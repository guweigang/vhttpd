module main

import net.websocket
import provider as provider_pkg
import upstream
import codex
import ws
import connection_runtime

// ── Builder: captures App closures ──

fn build_provider_websocket_context(mut host ProviderWebSocketHost) ws.UpstreamRuntimeContext {
	return ws.UpstreamRuntimeContext{
		enabled_fn:         fn [mut host] (provider string, instance string) bool {
			return host.websocket_upstream_provider_enabled(provider, instance)
		}
		reconnect_delay_fn: fn [mut host] (provider string, instance string) int {
			return host.websocket_upstream_provider_reconnect_delay_ms(provider, instance)
		}
		connecting_fn:      fn [mut host] (provider string, instance string) {
			host.websocket_upstream_provider_on_connecting(provider, instance)
		}
		pull_url_fn:        fn [mut host] (provider string, instance string) !string {
			return host.websocket_upstream_provider_pull_url(provider, instance)
		}
		prepare_fn:         fn [mut host] (provider string, instance string, ws_url string) !ws.UpstreamPreparation {
			return host.prepare_provider_websocket_handshake(provider, instance, ws_url)
		}
		connected_fn:       fn [mut host] (provider string, instance string, ws_url string) {
			host.websocket_upstream_provider_on_connected(provider, instance, ws_url)
			host.emit('websocket_upstream.connected', {
				'provider': provider
				'instance': instance
				'url':      ws_url
			})
		}
		disconnected_fn:    fn [mut host] (provider string, instance string, reason string) {
			host.websocket_upstream_provider_on_disconnected(provider, instance, reason)
		}
		handle_message_fn:  fn [mut host] (provider string, instance string, mut ws_client websocket.Client, msg &websocket.Message) ! {
			host.websocket_upstream_provider_handle_message(provider, instance, mut ws_client, msg)!
		}
		post_connect_fn:    fn [mut host] (provider string, instance string, ws_url string, mut session connection_runtime.Session, mut client websocket.Client) []thread {
			if session.stopped() { return []thread{} }
			return host.provider_websocket_post_connect(provider, instance, ws_url, mut session, mut client)
		}
		release_client_fn:  fn (_ string, _ string, _ &websocket.Client) {}
	}
}

fn (mut app App) build_websocket_upstream_runtime_context() ws.UpstreamRuntimeContext {
	return build_provider_websocket_context(mut app)
}

fn (mut app App) provider_websocket_post_connect(provider string, instance string, ws_url string, mut session connection_runtime.Session, mut client websocket.Client) []thread {
	mut workers := []thread{}
	if session.stopped() { return workers }
	if provider == websocket_upstream_provider_feishu {
		state := app.command_feishu_state()
		workers << spawn FeishuRuntimeHeartbeat.loop(state, instance, ws_url, mut session, mut client)
	} else if provider == websocket_upstream_provider_codex {
		workers << spawn app.codex_post_connect_handshake(instance, mut session, mut client)
		workers << spawn codex.WebSocketHeartbeat.loop(mut session, mut client)
	}
	return workers
}

// ── Provider routing ──

fn (mut app App) websocket_upstream_snapshot(provider string, instance string) ?upstream.UpstreamSnapshot {
	return match provider {
		websocket_upstream_provider_feishu {
			app.provider_runtime_upstream_snapshot(provider_pkg.ProviderName.feishu(), instance)
		}
		websocket_upstream_provider_fixture {
			return upstream_snapshot_from_ws(app.websocket.fixture_snapshot(instance))
		}
		websocket_upstream_provider_codex {
			app.provider_runtime_upstream_snapshot(provider_pkg.ProviderName.codex(), instance)
		}
		else {
			none
		}
	}
}

// ── Provider lifecycle ──

fn (mut app App) ensure_websocket_upstream_provider_running(provider string, instance string) bool {
	resolved_provider := provider.trim_space()
	mut resolved_instance := instance.trim_space()
	if resolved_provider == '' {
		return false
	}
	if !app.websocket.dynamic_upstream_autostart_enabled() {
		return false
	}
	if resolved_instance == '' {
		resolved_instance = app.provider_runtime_default_instance(resolved_provider)
	}
	if resolved_instance == '' {
		return false
	}
	if !app.provider_runtime_upstream_enabled(resolved_provider, resolved_instance) {
		return false
	}
	key := ws.UpstreamRuntimeContext.started_key(resolved_provider, resolved_instance)
	mut run := app.websocket.upstream_runs.reserve(key) or { return false }
	go WebSocketUpstreamRuntime.run_provider(mut app, resolved_provider, resolved_instance, mut run)
	return true
}

fn WebSocketUpstreamRuntime.run_provider(mut app App, provider string, instance string, mut run connection_runtime.Run) {
	defer { app.websocket.upstream_runs.release(ws.UpstreamRuntimeContext.started_key(provider, instance), mut run) }
	rt := app.build_websocket_upstream_runtime_context()
	rt.run_provider(provider, instance, mut run)
}
