module relay

import dispatch

pub struct DeliveryProjection {
pub:
	relay_id string
	frame    WireFrame
	plan     CarrierDispatchPlan
	error    string
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
		relay_id: relay_id
		frame:    frame
		plan:     carrier_dispatch_plan(registry, relay_id, frame)
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
