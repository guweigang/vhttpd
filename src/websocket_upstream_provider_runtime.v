module main

import net.websocket
import provider as provider_pkg
import upstream
import codex
import ws

// ── Builder: captures App closures ──

fn (mut app App) build_websocket_upstream_runtime_context() ws.UpstreamRuntimeContext {
	return ws.UpstreamRuntimeContext{
		enabled_fn:         fn [mut app] (provider string, instance string) bool {
			return app.websocket_upstream_provider_enabled(provider, instance)
		}
		reconnect_delay_fn: fn [mut app] (provider string, instance string) int {
			return app.websocket_upstream_provider_reconnect_delay_ms(provider, instance)
		}
		connecting_fn:      fn [mut app] (provider string, instance string) {
			app.websocket_upstream_provider_on_connecting(provider, instance)
		}
		pull_url_fn:        fn [mut app] (provider string, instance string) !string {
			return app.websocket_upstream_provider_pull_url(provider, instance)
		}
		connected_fn:       fn [mut app] (provider string, instance string, ws_url string) {
			app.websocket_upstream_provider_on_connected(provider, instance, ws_url)
			app.emit('websocket_upstream.connected', {
				'provider': provider
				'instance': instance
				'url':      ws_url
			})
		}
		disconnected_fn:    fn [mut app] (provider string, instance string, reason string) {
			app.websocket_upstream_provider_on_disconnected(provider, instance, reason)
		}
		handle_message_fn:  fn [mut app] (provider string, instance string, mut ws_client websocket.Client, msg &websocket.Message) ! {
			app.websocket_upstream_provider_handle_message(provider, instance, mut ws_client, msg)!
		}
		post_connect_fn:    fn [mut app] (provider string, instance string, ws_url string, mut client websocket.Client) {
			if provider == websocket_upstream_provider_feishu {
				mut feishu_app_ref := unsafe { &app }
				go FeishuRuntimeHeartbeat.loop(mut feishu_app_ref, instance, ws_url, mut client)
			} else if provider == websocket_upstream_provider_codex {
				mut codex_app_ref := unsafe { &app }
				go codex_app_ref.codex_post_connect_handshake(instance, mut client)
				go codex.WebSocketHeartbeat.loop(mut client)
			}
		}
	}
}

// ── Provider routing ──

fn (mut app App) websocket_upstream_snapshot(provider string, instance string) ?upstream.UpstreamSnapshot {
	return match provider {
		websocket_upstream_provider_feishu {
			app.provider_runtime_upstream_snapshot(provider_pkg.ProviderName.feishu(), instance)
		}
		websocket_upstream_provider_fixture {
			return upstream_snapshot_from_ws(app.transport.websocket.fixture_snapshot(instance))
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

fn (mut app App) websocket_upstream_mark_started(provider string, instance string) bool {
	key := ws.UpstreamRuntimeContext.started_key(provider, instance)
	if key == '/' || provider.trim_space() == '' || instance.trim_space() == '' {
		return false
	}
	app.transport.websocket.upstream_mu.@lock()
	defer {
		app.transport.websocket.upstream_mu.unlock()
	}
	if key in app.transport.websocket.upstream_started {
		return false
	}
	app.transport.websocket.upstream_started[key] = true
	return true
}

fn (mut app App) ensure_websocket_upstream_provider_running(provider string, instance string) bool {
	resolved_provider := provider.trim_space()
	mut resolved_instance := instance.trim_space()
	if resolved_provider == '' {
		return false
	}
	if !app.transport.websocket.auto_start_dynamic_upstreams {
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
	if !app.websocket_upstream_mark_started(resolved_provider, resolved_instance) {
		return false
	}
	go WebSocketUpstreamRuntime.run_provider(mut app, resolved_provider, resolved_instance)
	return true
}

fn WebSocketUpstreamRuntime.run_provider(mut app App, provider string, instance string) {
	rt := app.build_websocket_upstream_runtime_context()
	rt.run_provider(provider, instance)
}
