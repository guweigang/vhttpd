module relay

import dispatch
import json

pub const wire_version = 1

pub enum WireFrameKind {
	hello
	hello_ack
	ping
	pong
	open
	data
	end
	cancel
	error
}

pub struct WireFrame {
pub:
	version        int = wire_version
	kind           WireFrameKind
	id             string
	request_id     string
	trace_id       string
	parent_id      string
	channel_id     string
	correlation_id string
	route          string
	exchange_kind  string
	metadata       map[string]string
	headers        map[string]string
	body           string
}

pub fn new_frame(kind WireFrameKind, id string, trace_id string) WireFrame {
	return WireFrame{
		version:  wire_version
		kind:     kind
		id:       id
		trace_id: trace_id
	}
}

pub fn frame_from_exchange(kind WireFrameKind, channel_id string, correlation_id string, exchange dispatch.Exchange) WireFrame {
	return WireFrame{
		version:        wire_version
		kind:           kind
		id:             exchange.identity.id
		request_id:     exchange.identity.request_id
		trace_id:       exchange.identity.trace_id
		parent_id:      exchange.identity.parent_id
		channel_id:     channel_id
		correlation_id: correlation_id
		route:          exchange.pipeline
		exchange_kind:  exchange.kind.str()
		metadata:       exchange.metadata.clone()
		headers:        exchange.headers.clone()
		body:           exchange_body(exchange)
	}
}

pub fn encode_frame(frame WireFrame) !string {
	validate_frame(frame)!
	return json.encode(frame)
}

pub fn decode_frame(raw string) !WireFrame {
	frame := json.decode(WireFrame, raw) or { return error('relay_wire_invalid_json:${err}') }
	validate_frame(frame)!
	return frame
}

pub fn validate_frame(frame WireFrame) ! {
	if frame.version != wire_version {
		return error('relay_wire_unsupported_version:${frame.version}')
	}
	if frame.kind in [.hello, .hello_ack, .ping, .pong] {
		if frame.id == '' {
			return error('relay_wire_missing_id')
		}
		return
	}
	if frame.trace_id == '' {
		return error('relay_wire_missing_trace_id')
	}
	if frame.channel_id == '' {
		return error('relay_wire_missing_channel_id')
	}
	if frame.id == '' {
		return error('relay_wire_missing_id')
	}
}

pub fn frame_is_pipeline_response(frame WireFrame) bool {
	if frame.id.starts_with('relay-response:') {
		return true
	}
	return frame.exchange_kind.trim_space().to_lower() in ['response', 'error']
}

fn exchange_body(exchange dispatch.Exchange) string {
	match exchange.payload {
		dispatch.RequestPayload {
			return exchange.payload.body
		}
		dispatch.ResponsePayload {
			return exchange.payload.body
		}
		dispatch.EventPayload {
			return exchange.payload.data
		}
		dispatch.StreamPayload {
			return exchange.payload.chunk
		}
		dispatch.SessionPayload {
			return exchange.payload.message
		}
		dispatch.ErrorPayload {
			return exchange.payload.message
		}
		dispatch.EmptyPayload {
			return ''
		}
	}
}
