module main

import log
import net.websocket

fn (mut app App) websocket_upstream_provider_enabled(provider string, instance string) bool {
	if provider == websocket_upstream_provider_fixture {
		return true
	}
	return app.provider_runtime_upstream_enabled(provider, instance)
}

fn (mut app App) websocket_upstream_provider_pull_url(provider string, instance string) !string {
	if provider == websocket_upstream_provider_fixture {
		return error('unknown websocket upstream provider ${provider}')
	}
	return app.provider_runtime_pull_url(provider, instance)
}

fn (mut app App) websocket_upstream_provider_on_connected(provider string, instance string, ws_url string) {
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_connected(provider, instance, ws_url)
}

fn (mut app App) websocket_upstream_provider_on_connecting(provider string, instance string) {
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_connecting(provider, instance)
}

fn (mut app App) websocket_upstream_provider_on_disconnected(provider string, instance string, reason string) {
	app.emit('websocket_upstream.disconnected', {
		'provider': provider
		'instance': instance
		'reason':   reason
	})
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_disconnected(provider, instance, reason)
}

fn (mut app App) websocket_upstream_provider_reconnect_delay_ms(provider string, instance string) int {
	if provider == websocket_upstream_provider_fixture {
		return 3000
	}
	return app.provider_runtime_reconnect_delay_ms(provider, instance)
}

fn (mut app App) websocket_upstream_provider_handle_message(provider string, instance string, mut ws_client websocket.Client, msg &websocket.Message) ! {
	if provider == websocket_upstream_provider_codex {
		mut payload_preview := ''
		if msg.opcode == .text_frame || msg.opcode == .binary_frame || msg.opcode == .continuation {
			raw := msg.payload.bytestr()
			payload_preview = if raw.len > 200 { raw[..200] + '...' } else { raw }
		}
		log.info('[codex][ws] 📨 opcode=${msg.opcode} payload_len=${msg.payload.len} instance=${instance} preview=${payload_preview}')
	}
	match provider {
		websocket_upstream_provider_feishu {
			app.feishu_provider_handle_binary_message(instance, mut ws_client, msg)!
		}
		websocket_upstream_provider_codex {
			if msg.opcode == .text_frame {
				app.codex_provider_handle_text_message(instance, msg.payload.bytestr())
			} else {
				log.warn('[codex][ws] ignored non-text opcode=${msg.opcode} payload_len=${msg.payload.len} instance=${instance}')
			}
		}
		else {}
	}
}
