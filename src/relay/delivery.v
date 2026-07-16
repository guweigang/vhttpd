module relay

import dispatch

pub struct DeliveryProjection {
pub:
	relay_id          string
	frame             WireFrame
	plan              CarrierDispatchPlan
	completion_policy ResponseCompletionPolicy
	error             string
}

pub struct ResponseCompletionPolicy {
pub:
	mode       string = 'accepted'
	timeout_ms int
}

pub fn delivery_projection(registry CarrierRegistry, outcome dispatch.DeliveryOutcome) DeliveryProjection {
	if outcome.kind != .relay_delivery {
		return DeliveryProjection{
			error: 'relay_delivery_invalid_outcome:${outcome.kind}'
		}
	}
	relay_id := relay_id_from_target(outcome.target)
	if relay_id == '' {
		return DeliveryProjection{
			error: 'relay_delivery_missing_target'
		}
	}
	frame := wire_frame_from_delivery_outcome(outcome)
	return DeliveryProjection{
		relay_id:          relay_id
		frame:             frame
		plan:              carrier_dispatch_plan(registry, relay_id, frame)
		completion_policy: response_completion_policy_from_metadata(outcome.metadata)
	}
}

pub fn wire_frame_from_delivery_outcome(outcome dispatch.DeliveryOutcome) WireFrame {
	metadata := outcome.metadata.clone()
	trace_id := metadata['trace_id'] or { '' }
	request_id := metadata['request_id'] or { '' }
	channel_id := metadata['channel_id'] or { metadata['relay_channel_id'] or { outcome.target } }
	correlation_id := metadata['correlation_id'] or { metadata['relay_correlation_id'] or { '' } }
	frame_id := metadata['frame_id'] or {
		if request_id != '' {
			request_id
		} else {
			channel_id
		}
	}
	return WireFrame{
		version:        wire_version
		kind:           delivery_frame_kind(metadata)
		id:             frame_id
		request_id:     request_id
		trace_id:       trace_id
		channel_id:     channel_id
		correlation_id: correlation_id
		route:          metadata['route'] or { metadata['pipeline'] or { '' } }
		exchange_kind:  metadata['exchange_kind'] or { '' }
		metadata:       metadata
		headers:        outcome.headers.clone()
		body:           metadata['body'] or { metadata['payload'] or { '' } }
	}
}

pub fn relay_id_from_target(target string) string {
	trimmed := target.trim_space()
	if trimmed == '' {
		return ''
	}
	if trimmed.starts_with('relay:') {
		rest := trimmed['relay:'.len..]
		if separator := rest.index(':') {
			return rest[..separator]
		}
		return rest
	}
	return trimmed
}

fn delivery_frame_kind(metadata map[string]string) WireFrameKind {
	match (metadata['frame_kind'] or { metadata['relay_frame_kind'] or { 'data' } }).trim_space().to_lower() {
		'open' { return .open }
		'end' { return .end }
		'cancel' { return .cancel }
		'error' { return .error }
		else { return .data }
	}
}

pub fn response_completion_policy_from_metadata(metadata map[string]string) ResponseCompletionPolicy {
	return ResponseCompletionPolicy{
		mode:       normalize_response_completion_mode(metadata['completion_mode'] or {
			metadata['relay_completion_mode'] or { metadata['response_mode'] or { 'accepted' } }
		})
		timeout_ms: response_completion_timeout_ms(metadata)
	}
}

fn normalize_response_completion_mode(raw string) string {
	match raw.trim_space().to_lower() {
		'wait', 'blocking', 'request_response', 'request-response' { return 'wait' }
		'stream', 'streaming' { return 'stream' }
		else { return 'accepted' }
	}
}

fn response_completion_timeout_ms(metadata map[string]string) int {
	for key in ['completion_timeout_ms', 'relay_completion_timeout_ms', 'response_timeout_ms',
		'timeout_ms'] {
		raw := (metadata[key] or { '' }).trim_space()
		if raw == '' {
			continue
		}
		value := raw.int()
		if value > 0 {
			return value
		}
	}
	return 0
}
