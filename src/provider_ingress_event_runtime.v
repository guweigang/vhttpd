module main

import time

fn (mut app App) dispatch_provider_ingress_event(provider string, instance string, trace_id string, activity_id string, event_type string, event_kind string, payload string, metadata map[string]string) bool {
	provider_id := provider.trim_space()
	if provider_id == '' {
		return false
	}
	mut event_metadata := metadata.clone()
	event_metadata['provider'] = provider_id
	if instance.trim_space() != '' {
		event_metadata['instance'] = instance.trim_space()
	}
	if event_type.trim_space() != '' {
		event_metadata['event_type'] = event_type.trim_space()
	}
	if event_kind.trim_space() != '' {
		event_metadata['event_kind'] = event_kind.trim_space()
	}
	request_id := if activity_id.trim_space() != '' {
		activity_id.trim_space()
	} else {
		'provider-${provider_id}-${time.now().unix_micro()}'
	}
	event_name := if event_type.trim_space() != '' {
		event_type.trim_space()
	} else if event_kind.trim_space() != '' {
		event_kind.trim_space()
	} else {
		'provider.${provider_id}'
	}
	event_trace_id := if trace_id.trim_space() != '' { trace_id.trim_space() } else { request_id }
	app.dispatch_runtime_event_request(RuntimeEventDispatchRequest{
		ingress:    'provider:${provider_id}'
		topic:      'provider.${provider_id}'
		name:       event_name
		data:       payload
		metadata:   event_metadata
		request_id: request_id
		trace_id:   event_trace_id
	}, request_id, event_trace_id) or {
		if err.msg().starts_with('runtime_event_pipeline_not_found:') {
			return false
		}
		app.emit('provider.ingress.dispatch_failed', {
			'provider':   provider_id
			'instance':   instance
			'request_id': request_id
			'trace_id':   event_trace_id
			'event':      event_name
			'error':      err.msg()
		})
		return false
	}
	return true
}
