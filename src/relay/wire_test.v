module relay

import dispatch

fn test_encode_decode_roundtrip_preserves_trace_and_channel() {
	frame := WireFrame{
		version:        wire_version
		kind:           .data
		id:             'frm_1'
		request_id:     'req_1'
		trace_id:       'trace_1'
		channel_id:     'chan_1'
		correlation_id: 'corr_1'
		metadata:       {
			'tenant': 'demo'
		}
		body:           'hello'
	}

	raw := encode_frame(frame) or { panic(err) }
	decoded := decode_frame(raw) or { panic(err) }

	assert decoded.version == wire_version
	assert decoded.kind == .data
	assert decoded.id == 'frm_1'
	assert decoded.request_id == 'req_1'
	assert decoded.trace_id == 'trace_1'
	assert decoded.channel_id == 'chan_1'
	assert decoded.correlation_id == 'corr_1'
	assert decoded.metadata['tenant'] == 'demo'
	assert decoded.body == 'hello'
}

fn test_decode_rejects_unsupported_wire_version() {
	raw := '{"version":999,"kind":"data","id":"frm_1","trace_id":"trace_1","channel_id":"chan_1"}'
	decode_frame(raw) or {
		assert err.msg().contains('relay_wire_unsupported_version:999')
		return
	}
	assert false
}

fn test_data_frame_requires_trace_and_channel() {
	validate_frame(WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_1'
		channel_id: 'chan_1'
	}) or {
		assert err.msg() == 'relay_wire_missing_trace_id'
		return
	}
	assert false
}

fn test_control_frame_requires_only_id() {
	validate_frame(WireFrame{
		version: wire_version
		kind:    .ping
		id:      'ping_1'
	}) or { panic(err) }
}

fn test_frame_from_exchange_projects_common_identity_and_body() {
	exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'ex_1'
			request_id: 'req_1'
			trace_id:   'trace_1'
			parent_id:  'span_0'
		}
		kind:     .request
		ingress:  'adapter:http'
		pipeline: 'site/main'
		headers:  {
			'content-type': 'text/plain'
		}
		metadata: {
			'provider': 'opaque-provider'
			'custom':   'value'
		}
		payload:  dispatch.RequestPayload{
			method: 'POST'
			path:   '/submit'
			body:   'payload'
		}
	}

	frame := frame_from_exchange(.data, 'chan_1', 'corr_1', exchange)

	assert frame.version == wire_version
	assert frame.id == 'ex_1'
	assert frame.request_id == 'req_1'
	assert frame.trace_id == 'trace_1'
	assert frame.parent_id == 'span_0'
	assert frame.channel_id == 'chan_1'
	assert frame.correlation_id == 'corr_1'
	assert frame.route == 'site/main'
	assert frame.exchange_kind == 'request'
	assert frame.headers['content-type'] == 'text/plain'
	assert frame.metadata['provider'] == 'opaque-provider'
	assert frame.metadata['custom'] == 'value'
	assert frame.body == 'payload'
}

fn test_frame_is_pipeline_response_detects_response_frames() {
	assert frame_is_pipeline_response(WireFrame{
		id:            'relay-response:frm_1'
		exchange_kind: 'response'
	})
	assert frame_is_pipeline_response(WireFrame{
		id:            'frm_error'
		exchange_kind: 'error'
	})
	assert !frame_is_pipeline_response(WireFrame{
		id:            'frm_request'
		exchange_kind: 'request'
	})
}

fn test_frame_response_target_id_uses_metadata_prefix_or_parent() {
	assert frame_response_target_id(WireFrame{
		id: 'relay-response:frm_1'
	}) == 'frm_1'
	assert frame_response_target_id(WireFrame{
		id:       'response_1'
		metadata: {
			'response_to': 'frm_2'
		}
	}) == 'frm_2'
	assert frame_response_target_id(WireFrame{
		id:        'response_2'
		parent_id: 'frm_3'
	}) == 'frm_3'
}
