module main

import net.websocket
import connection_runtime
import ws

interface ProviderWebSocketHost {
mut:
	websocket_upstream_provider_enabled(provider string, instance string) bool
	websocket_upstream_provider_reconnect_delay_ms(provider string, instance string) int
	websocket_upstream_provider_on_connecting(provider string, instance string)
	websocket_upstream_provider_pull_url(provider string, instance string) !string
	websocket_upstream_provider_on_connected(provider string, instance string, ws_url string)
	websocket_upstream_provider_on_disconnected(provider string, instance string, reason string)
	websocket_upstream_provider_handle_message(provider string, instance string, mut ws_client websocket.Client, msg &websocket.Message) !
	prepare_provider_websocket_handshake(provider_name string, instance string, ws_url string) !ws.UpstreamPreparation
	provider_websocket_post_connect(provider string, instance string, ws_url string, mut session connection_runtime.Session, mut client websocket.Client) []thread
	emit(kind string, fields map[string]string)
}
