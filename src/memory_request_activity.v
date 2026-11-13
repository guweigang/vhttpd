module main

import memidle
import net.http

// veb invokes these optional hooks on every dispatch path, including native,
// static, admin, refusing middleware, 404/405 and parser-error early returns.
fn (mut app App) before_handle_request(req http.Request) {
	if is_websocket_upgrade(req) { memidle.touch() } else { memidle.begin() }
}
fn (mut app App) after_handle_request(req http.Request) {
	if is_websocket_upgrade(req) { memidle.touch() } else { memidle.end() }
}
fn (mut app AdminApp) before_handle_request(req http.Request) { memidle.begin() }
fn (mut app AdminApp) after_handle_request(req http.Request) { memidle.end() }
