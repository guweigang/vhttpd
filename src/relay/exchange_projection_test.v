module relay

fn test_relay_ingress_request_from_frame_projects_pipeline_fields() {
	req := relay_ingress_request_from_frame('edge', 'agent:edge', WireFrame{
		version:       wire_version
		kind:          .data
		id:            'frm-1'
		request_id:    'req-1'
		trace_id:      'trace-1'
		channel_id:    'chan-1'
		route:         'http'
		exchange_kind: 'request'
		metadata:      {
			'session_id': 'sess-1'
			'link_id':    'producer'
		}
		body:          'payload'
	}, 'edge/local', 123)

	assert req.relay_id == 'edge'
	assert req.carrier_id == 'agent:edge'
	assert req.frame_id == 'frm-1'
	assert req.channel_id == 'chan-1'
	assert req.session_id == 'sess-1'
	assert req.link_id == 'producer'
	assert req.trace_id == 'trace-1'
	assert req.request_id == 'req-1'
	assert req.ingress == 'relay:edge'
	assert req.pipeline == 'edge/local'
	assert req.kind == .request
	assert req.body == 'payload'
	assert req.created_at_ms == 123
}

fn test_relay_ingress_request_from_frame_defaults_session_and_request_ids() {
	req := relay_ingress_request_from_frame('edge', 'agent:edge', WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm-open'
		trace_id:   'trace-1'
		channel_id: 'chan-1'
		route:      'control'
	}, 'edge/open', 0)

	assert req.request_id == 'frm-open'
	assert req.session_id == 'chan-1'
	assert req.link_id == 'control'
	assert req.kind == .session_open
}

fn test_relay_exchange_kind_from_frame_maps_close_and_error() {
	assert relay_exchange_kind_from_frame(WireFrame{ kind: .end }) == .session_close
	assert relay_exchange_kind_from_frame(WireFrame{ kind: .cancel }) == .session_close
	assert relay_exchange_kind_from_frame(WireFrame{ kind: .error }) == .error
	assert relay_exchange_kind_from_frame(WireFrame{
		kind:          .data
		exchange_kind: 'stream_chunk'
	}) == .stream_chunk
	assert relay_exchange_kind_from_frame(WireFrame{ kind: .data }) == .session_message
}
