module ws

import net.websocket
import connection_runtime
import time

// Cold plugin loading and handshake construction finish before TCP/HTTP upgrade.
// Activation only writes the prepared result to this attempt's connected client.
pub struct UpstreamPreparation {
pub:
	activate_fn fn (mut websocket.Client) ! @[required]
}

// UpstreamRuntimeContext is the closure-based interface for WebSocket upstream provider operations.
pub struct UpstreamRuntimeContext {
pub:
	enabled_fn         fn (string, string) bool                                        @[required]
	reconnect_delay_fn fn (string, string) int                                         @[required]
	connecting_fn      fn (string, string)                                             @[required]
	pull_url_fn        fn (string, string) !string                                     @[required]
	prepare_fn         fn (string, string, string) !UpstreamPreparation                @[required]
	connected_fn       fn (string, string, string)                                     @[required]
	disconnected_fn    fn (string, string, string)                                     @[required]
	handle_message_fn  fn (string, string, mut websocket.Client, &websocket.Message) ! @[required]
	post_connect_fn    fn (string, string, string, mut connection_runtime.Session, mut websocket.Client) []thread @[required]
	release_client_fn  fn (string, string, &websocket.Client) @[required]
}

pub fn (rt UpstreamRuntimeContext) enabled(provider string, instance string) bool {
	return rt.enabled_fn(provider, instance)
}

pub fn (rt UpstreamRuntimeContext) reconnect_delay_ms(provider string, instance string) int {
	return rt.reconnect_delay_fn(provider, instance)
}

pub fn (rt UpstreamRuntimeContext) on_connecting(provider string, instance string) {
	rt.connecting_fn(provider, instance)
}

pub fn (rt UpstreamRuntimeContext) pull_url(provider string, instance string) !string {
	return rt.pull_url_fn(provider, instance)
}

pub fn (rt UpstreamRuntimeContext) on_connected(provider string, instance string, ws_url string) {
	rt.connected_fn(provider, instance, ws_url)
}

pub fn (rt UpstreamRuntimeContext) on_disconnected(provider string, instance string, reason string) {
	rt.disconnected_fn(provider, instance, reason)
}

pub fn (rt UpstreamRuntimeContext) handle_message(provider string, instance string, mut ws_client websocket.Client, msg &websocket.Message) ! {
	rt.handle_message_fn(provider, instance, mut ws_client, msg)!
}

pub fn (rt UpstreamRuntimeContext) post_connect(provider string, instance string, ws_url string, mut session connection_runtime.Session, mut client websocket.Client) []thread {
	return rt.post_connect_fn(provider, instance, ws_url, mut session, mut client)
}

pub fn UpstreamRuntimeContext.started_key(provider string, instance string) string {
	return '${provider.trim_space()}/${instance.trim_space()}'
}

// Per-attempt callback state cannot outlive its joined session tasks.
@[heap]
pub struct UpstreamRef {
pub mut:
	rt       UpstreamRuntimeContext @[required]
	provider string
	instance string
	session  &connection_runtime.Session @[required]
}

pub fn (rt UpstreamRuntimeContext) run_provider(provider string, instance string, mut run connection_runtime.Run) {
	defer { run.finish() }
	for !run.stopped() && rt.enabled(provider, instance) {
		upstream_attempt(rt, provider, instance, mut run)
		if !rt.enabled(provider, instance) || !run.wait(rt.reconnect_delay_ms(provider, instance) * time.millisecond) {
			break
		}
	}
}

fn upstream_attempt(rt UpstreamRuntimeContext, provider string, instance string, mut run connection_runtime.Run) {
	if run.stopped() { return }
	rt.on_connecting(provider, instance)
	ws_url := rt.pull_url(provider, instance) or {
		rt.on_disconnected(provider, instance, 'endpoint:${err}')
		return
	}
	if run.stopped() || !rt.enabled(provider, instance) { return }
	prepared := rt.prepare_fn(provider, instance, ws_url) or {
		rt.on_disconnected(provider, instance, 'prepare:${err}')
		return
	}
	if run.stopped() || !rt.enabled(provider, instance) { return }
	mut client := websocket.new_client(ws_url,
		read_timeout:  60 * time.second
		write_timeout: 5 * time.second
	) or {
		rt.on_disconnected(provider, instance, 'client:${err}')
		return
	}
	mut session_owned := false
	defer { if !session_owned { connection_runtime.close_client(mut client) } }
	mut session := connection_runtime.connect_websocket(mut client, mut run) or {
		rt.on_disconnected(provider, instance, 'connect:${err}')
		return
	}
	session_owned = true
	mut workers := []thread{}
	defer {
		session.request_stop()
		workers.wait()
		run.detach(session)
		connection_runtime.close_client(mut client)
		rt.release_client_fn(provider, instance, client)
		session.release()
		rt.on_disconnected(provider, instance, session.disconnect_reason())
	}
	mut ref := &UpstreamRef{ rt: rt, provider: provider, instance: instance, session: session }
	client.on_message_ref(upstream_message_cb, ref)
	client.on_error_ref(upstream_error_cb, ref)
	client.on_close_ref(upstream_close_cb, ref)
	if run.stopped() || !rt.enabled(provider, instance) { return }
	rt.on_connected(provider, instance, ws_url)
	if session.stopped() { return }
	prepared.activate_fn(mut client) or {
		session.note_reason('handshake:${err}')
		return
	}
	workers = rt.post_connect(provider, instance, ws_url, mut session, mut client)
	if !session.stopped() { client.listen() or { session.note_reason('listen:${err}') } }
}

fn upstream_message_cb(mut ws_client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &UpstreamRef(ref) }
	if state.session.stopped() { return }
	state.rt.handle_message(state.provider, state.instance, mut ws_client, msg)!
}

fn upstream_error_cb(mut _ws websocket.Client, err string, ref voidptr) ! {
	mut state := unsafe { &UpstreamRef(ref) }
	state.session.note_reason('error:${err}')
	state.session.request_stop()
}

fn upstream_close_cb(mut _ws websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &UpstreamRef(ref) }
	state.session.note_reason('close:${code}:${reason}')
	state.session.request_stop()
}
