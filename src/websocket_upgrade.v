module main

import net.http

struct WebSocketUpgrade {}

fn WebSocketUpgrade.key(req http.Request) string {
	return websocket_upgrade_key(req)
}

fn WebSocketUpgrade.is_upgrade(req http.Request) bool {
	return is_websocket_upgrade(req)
}
