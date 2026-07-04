module relay

import dispatch

pub fn relay_ingress_request_from_frame(relay_id string, carrier_id string, frame WireFrame, pipeline_id string, created_at_ms i64) dispatch.RelayIngressRequest {
	session_id := frame.metadata['session_id'] or { frame.channel_id }
	return dispatch.RelayIngressRequest{
		relay_id:      relay_id
		carrier_id:    carrier_id
		frame_id:      frame.id
		channel_id:    frame.channel_id
		session_id:    session_id
		link_id:       frame.metadata['link_id'] or { frame.route }
		trace_id:      frame.trace_id
		request_id:    if frame.request_id != '' { frame.request_id } else { frame.id }
		exchange_id:   frame.id
		ingress:       'relay:${relay_id}'
		pipeline:      pipeline_id
		kind:          relay_exchange_kind_from_frame(frame)
		body:          frame.body
		headers:       frame.headers.clone()
		metadata:      frame.metadata.clone()
		created_at_ms: created_at_ms
	}
}

pub fn relay_exchange_kind_from_frame(frame WireFrame) dispatch.ExchangeKind {
	match frame.kind {
		.open {
			return .session_open
		}
		.data {
			return relay_exchange_kind_from_string(frame.exchange_kind)
		}
		.end, .cancel {
			return .session_close
		}
		.error {
			return .error
		}
		.hello, .hello_ack, .ping, .pong {
			return .event
		}
	}
}

fn relay_exchange_kind_from_string(value string) dispatch.ExchangeKind {
	match value.trim_space().to_lower() {
		'request' { return .request }
		'response' { return .response }
		'event' { return .event }
		'stream_open' { return .stream_open }
		'stream_chunk' { return .stream_chunk }
		'stream_end' { return .stream_end }
		'session_open' { return .session_open }
		'session_close' { return .session_close }
		'error' { return .error }
		else { return .session_message }
	}
}
