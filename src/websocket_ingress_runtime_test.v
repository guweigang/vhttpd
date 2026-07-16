module main

import net.http

fn websocket_upgrade_request(method http.Method, upgrade string, connection string, key string) http.Request {
	mut req := http.Request{
		method: method
	}
	req.header.set_custom('Upgrade', upgrade) or { panic(err) }
	req.header.set_custom('Connection', connection) or { panic(err) }
	req.header.set_custom('Sec-WebSocket-Key', key) or { panic(err) }
	return req
}

fn test_is_websocket_upgrade_accepts_standard_upgrade_headers() {
	req := websocket_upgrade_request(.get, 'websocket', 'keep-alive, Upgrade', 'test-key')
	assert is_websocket_upgrade(req)
}

fn test_is_websocket_upgrade_rejects_non_get_requests() {
	req := websocket_upgrade_request(.post, 'websocket', 'Upgrade', 'test-key')
	assert !is_websocket_upgrade(req)
}

fn test_is_websocket_upgrade_requires_websocket_key() {
	req := websocket_upgrade_request(.get, 'websocket', 'Upgrade', '')
	assert !is_websocket_upgrade(req)
}
