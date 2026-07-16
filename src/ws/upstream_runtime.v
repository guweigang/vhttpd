module ws

import net.websocket
import time

// UpstreamRuntimeContext is the closure-based interface for WebSocket upstream provider operations.
pub struct UpstreamRuntimeContext {
pub:
	enabled_fn         fn (string, string) bool    = unsafe { nil }
	reconnect_delay_fn fn (string, string) int     = unsafe { nil }
	connecting_fn      fn (string, string)         = unsafe { nil }
	pull_url_fn        fn (string, string) !string = unsafe { nil }
	connected_fn       fn (string, string, string) = unsafe { nil }
	disconnected_fn    fn (string, string, string) = unsafe { nil }
	handle_message_fn  fn (string, string, mut websocket.Client, &websocket.Message) ! = unsafe { nil }
	post_connect_fn    fn (string, string, string, mut websocket.Client)               = unsafe { nil }
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

pub fn (rt UpstreamRuntimeContext) post_connect(provider string, instance string, ws_url string, mut client websocket.Client) {
	rt.post_connect_fn(provider, instance, ws_url, mut client)
}

pub fn UpstreamRuntimeContext.started_key(provider string, instance string) string {
	return '${provider.trim_space()}/${instance.trim_space()}'
}

// UpstreamRef is the heap-allocated callback state passed to the websocket client.
@[heap]
pub struct UpstreamRef {
pub mut:
	rt       UpstreamRuntimeContext
	provider string
	instance string
}

pub fn upstream_run_provider(rt UpstreamRuntimeContext, provider string, instance string) {
	if !rt.enabled(provider, instance) {
		return
	}
	reconnect_delay := rt.reconnect_delay_ms(provider, instance)
	mut ref := &UpstreamRef{
		rt:       rt
		provider: provider
		instance: instance
	}
	for {
		rt.on_connecting(provider, instance)
		ws_url := rt.pull_url(provider, instance) or {
			rt.on_disconnected(provider, instance, 'endpoint:${err}')
			time.sleep(reconnect_delay * time.millisecond)
			continue
		}
		mut client := websocket.new_client(ws_url,
			read_timeout:  60 * time.second
			write_timeout: 60 * time.second
		) or {
			rt.on_disconnected(provider, instance, 'client:${err}')
			time.sleep(reconnect_delay * time.millisecond)
			continue
		}
		client.on_message_ref(upstream_message_cb, voidptr(ref))
		client.on_error_ref(upstream_error_cb, voidptr(ref))
		client.on_close_ref(upstream_close_cb, voidptr(ref))
		client.connect() or {
			rt.on_disconnected(provider, instance, 'connect:${err}')
			time.sleep(reconnect_delay * time.millisecond)
			continue
		}
		rt.on_connected(provider, instance, ws_url)
		rt.post_connect(provider, instance, ws_url, mut client)
		client.listen() or { rt.on_disconnected(provider, instance, 'listen:${err}') }
		time.sleep(reconnect_delay * time.millisecond)
	}
}

pub fn (rt UpstreamRuntimeContext) run_provider(provider string, instance string) {
	upstream_run_provider(rt, provider, instance)
}

fn upstream_message_cb(mut ws_client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &UpstreamRef(ref) }
	state.rt.handle_message(state.provider, state.instance, mut ws_client, msg)!
}

fn upstream_error_cb(mut _ws websocket.Client, err string, ref voidptr) ! {
	mut state := unsafe { &UpstreamRef(ref) }
	state.rt.on_disconnected(state.provider, state.instance, 'error:${err}')
}

fn upstream_close_cb(mut _ws websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &UpstreamRef(ref) }
	state.rt.on_disconnected(state.provider, state.instance, 'close:${code}:${reason}')
}
