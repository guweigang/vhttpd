module dispatch

pub struct RelayDeliveryAdapter {
pub:
	name            string
	target          string
	completion_mode string
	timeout_ms      int
	metadata        map[string]string
}

pub fn relay_delivery_adapter(id string, target string, completion_mode string, timeout_ms int, metadata map[string]string) RelayDeliveryAdapter {
	return RelayDeliveryAdapter{
		name:            id
		target:          target
		completion_mode: completion_mode
		timeout_ms:      timeout_ms
		metadata:        metadata.clone()
	}
}

pub fn (adapter RelayDeliveryAdapter) id() string {
	return adapter.name
}

pub fn (adapter RelayDeliveryAdapter) capabilities() Capabilities {
	_ = adapter
	return Capabilities{
		request_response: true
	}
}

pub fn (mut adapter RelayDeliveryAdapter) warmup(mut services RuntimeServices) ! {
	_ = adapter
	_ = services
}

pub fn (mut adapter RelayDeliveryAdapter) deliver(mut services RuntimeServices, exchange Exchange) !DeliveryOutcome {
	mut metadata := adapter.metadata.clone()
	metadata['trace_id'] = exchange.identity.trace_id
	metadata['request_id'] = exchange.identity.request_id
	metadata['frame_id'] = exchange.identity.id
	metadata['channel_id'] = adapter_channel_id(adapter, exchange)
	if route := metadata['route'] {
		if route.trim_space() == '' {
			metadata.delete('route')
		}
	}
	if metadata['route'] or { '' } == '' && exchange.pipeline != '' {
		metadata['route'] = exchange.pipeline
	}
	if metadata['frame_kind'] or { '' } == '' {
		metadata['frame_kind'] = 'open'
	}
	body := relay_delivery_adapter_body(exchange)
	if body != '' {
		metadata['body'] = body
	}
	if request := relay_delivery_adapter_request(exchange) {
		metadata['http_method'] = request.method
		metadata['path'] = request.path
	}
	if services.trace_id() != '' {
		metadata['trace_id'] = services.trace_id()
	}
	return DeliveryOutcome{
		...relay_delivery_outcome_with_completion(adapter.target, metadata,
			adapter.completion_mode, adapter.timeout_ms)
		headers: exchange.headers.clone()
	}
}

pub fn (mut adapter RelayDeliveryAdapter) close() {
	_ = adapter
}

fn adapter_channel_id(adapter RelayDeliveryAdapter, exchange Exchange) string {
	if channel_id := adapter.metadata['channel_id'] {
		if channel_id.trim_space() != '' {
			return channel_id
		}
	}
	if exchange.identity.request_id != '' {
		return exchange.identity.request_id
	}
	return exchange.identity.id
}

fn relay_delivery_adapter_body(exchange Exchange) string {
	match exchange.payload {
		RequestPayload { return exchange.payload.body }
		ResponsePayload { return exchange.payload.body }
		EventPayload { return exchange.payload.data }
		StreamPayload { return exchange.payload.chunk }
		SessionPayload { return exchange.payload.message }
		ErrorPayload { return exchange.payload.message }
		EmptyPayload { return '' }
	}
}

fn relay_delivery_adapter_request(exchange Exchange) ?RequestPayload {
	match exchange.payload {
		RequestPayload { return exchange.payload }
		else { return none }
	}
}
