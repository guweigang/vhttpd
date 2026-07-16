module main

import encoding.base64
import json
import net.websocket
import time

struct ProviderWebSocketHookFrame {
pub:
	text   string
	binary string
}

struct ProviderWebSocketHandshakeResult {
pub:
	send   []ProviderWebSocketHookFrame
	frames []ProviderWebSocketHookFrame
}

struct ProviderWebSocketHookPayload {
pub:
	provider string
	instance string
	url      string
	payload  string
	metadata map[string]string
}

struct ProviderWebSocketNormalizeResult {
pub:
	skip       bool
	topic      string
	name       string
	data       string
	metadata   map[string]string
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
}

fn (mut app App) provider_websocket_hook_plugin(provider_name string, hook string) string {
	_ = hook
	if app.providers.provider_runtime_protocol(provider_name).trim_space().to_lower() !in [
		'websocket',
		'ws',
	] {
		return ''
	}
	return app.providers.provider_runtime_plugin(provider_name)
}

fn (mut app App) provider_websocket_hook_method(provider_name string, hook string) string {
	method := app.providers.provider_runtime_hook(provider_name, hook).trim_space()
	if method != '' {
		return method
	}
	return hook
}

fn provider_websocket_hook_payload(provider_name string, instance string, ws_url string, payload string, metadata map[string]string) string {
	return json.encode(ProviderWebSocketHookPayload{
		provider: provider_name
		instance: instance
		url:      ws_url
		payload:  payload
		metadata: metadata
	})
}

fn (mut app App) call_provider_websocket_hook(provider_name string, instance string, hook string, ws_url string, payload string, metadata map[string]string, request_id string, trace_id string) !PluginCallResponse {
	plugin_name := app.provider_websocket_hook_plugin(provider_name, hook)
	if plugin_name == '' {
		return error('provider_websocket_hook_plugin_missing:${provider_name}:${hook}')
	}
	return app.call_plugin(PluginCallRequest{
		plugin:     plugin_name
		capability: app.provider_websocket_hook_method(provider_name, hook)
		op:         'websocket_${hook}'
		request_id: request_id
		trace_id:   trace_id
		payload:    provider_websocket_hook_payload(provider_name, instance, ws_url, payload,
			metadata)
		metadata:   metadata
	})!
}

fn (mut app App) dispatch_provider_websocket_handshake(provider_name string, instance string, ws_url string, mut client websocket.Client) {
	if app.provider_websocket_hook_plugin(provider_name, 'handshake') == '' {
		return
	}
	request_id := 'provider-${provider_name}-${instance}-handshake-${time.now().unix_micro()}'
	metadata := {
		'provider': provider_name
		'instance': instance
		'hook':     'handshake'
		'url':      ws_url
	}
	resp := app.call_provider_websocket_hook(provider_name, instance, 'handshake', ws_url, '',
		metadata, request_id, request_id) or {
		app.emit('provider.websocket.handshake_failed', {
			'provider': provider_name
			'instance': instance
			'error':    err.msg()
		})
		return
	}
	result := json.decode(ProviderWebSocketHandshakeResult, resp.result) or {
		app.emit('provider.websocket.handshake_failed', {
			'provider': provider_name
			'instance': instance
			'error':    'invalid_result:${err.msg()}'
		})
		return
	}
	mut frames := result.send.clone()
	frames << result.frames
	for frame in frames {
		if frame.text != '' {
			client.write_string(frame.text) or {
				app.emit('provider.websocket.handshake_failed', {
					'provider': provider_name
					'instance': instance
					'error':    'send_text:${err.msg()}'
				})
				return
			}
		} else if frame.binary != '' {
			bytes := base64.decode(frame.binary)
			client.write(bytes, .binary_frame) or {
				app.emit('provider.websocket.handshake_failed', {
					'provider': provider_name
					'instance': instance
					'error':    'send_binary:${err.msg()}'
				})
				return
			}
		}
	}
	app.emit('provider.websocket.handshake_dispatched', {
		'provider': provider_name
		'instance': instance
		'frames':   '${frames.len}'
	})
}

fn (mut app App) dispatch_provider_websocket_normalized_event(provider_name string, instance string, ws_url string, raw_payload string, metadata map[string]string, request_id string, trace_id string) bool {
	if app.provider_websocket_hook_plugin(provider_name, 'normalize') == '' {
		return false
	}
	resp := app.call_provider_websocket_hook(provider_name, instance, 'normalize', ws_url,
		raw_payload, metadata, request_id, trace_id) or {
		app.emit('provider.websocket.normalize_failed', {
			'provider':   provider_name
			'instance':   instance
			'request_id': request_id
			'trace_id':   trace_id
			'error':      err.msg()
		})
		return false
	}
	result := json.decode(ProviderWebSocketNormalizeResult, resp.result) or {
		app.emit('provider.websocket.normalize_failed', {
			'provider':   provider_name
			'instance':   instance
			'request_id': request_id
			'trace_id':   trace_id
			'error':      'invalid_result:${err.msg()}'
		})
		return false
	}
	if result.skip {
		return true
	}
	mut event_metadata := metadata.clone()
	for key, value in result.metadata {
		event_metadata[key] = value
	}
	event_metadata['provider'] = provider_name
	event_metadata['instance'] = instance
	name := if result.name.trim_space() != '' { result.name.trim_space() } else { event_metadata['event_type'] or {
			'provider.${provider_name}'} }
	event_trace_id := if result.trace_id.trim_space() != '' {
		result.trace_id.trim_space()
	} else {
		trace_id
	}
	event_request_id := if result.request_id.trim_space() != '' {
		result.request_id.trim_space()
	} else {
		request_id
	}
	app.dispatch_runtime_event_request(RuntimeEventDispatchRequest{
		ingress:    'provider:${provider_name}'
		topic:      if result.topic.trim_space() != '' {
			result.topic.trim_space()
		} else {
			'provider.${provider_name}'
		}
		name:       name
		data:       result.data
		metadata:   event_metadata
		request_id: event_request_id
		trace_id:   event_trace_id
	}, event_request_id, event_trace_id) or {
		if err.msg().starts_with('runtime_event_pipeline_not_found:') {
			return false
		}
		app.emit('provider.websocket.normalize_dispatch_failed', {
			'provider':   provider_name
			'instance':   instance
			'request_id': event_request_id
			'trace_id':   event_trace_id
			'error':      err.msg()
		})
		return false
	}
	return true
}
