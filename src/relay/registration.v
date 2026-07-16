module relay

pub struct RegistrationRequest {
pub:
	node_id      string
	relay_id     string
	mode         RelayMode
	carrier      string
	token        string
	trace_id     string
	max_channels int
}

pub struct RegistrationResult {
pub:
	accepted   bool
	node_id    string
	relay_id   string
	trace_id   string
	error      string
	retry_after_ms int
}

pub fn registration_request_from_descriptor(descriptor RelayDescriptor, trace_id string) RegistrationRequest {
	return RegistrationRequest{
		node_id:      descriptor.node_id
		relay_id:     descriptor.id
		mode:         descriptor.mode
		carrier:      descriptor.carrier
		token:        descriptor.token
		trace_id:     trace_id
		max_channels: descriptor.max_channels
	}
}

pub fn registration_hello_frame(req RegistrationRequest) !WireFrame {
	validate_registration_request(req)!
	return WireFrame{
		version:    wire_version
		kind:       .hello
		id:         'relay-hello:${req.node_id}'
		trace_id:   req.trace_id
		metadata:   {
			'node_id':      req.node_id
			'relay_id':     req.relay_id
			'mode':         req.mode.str()
			'carrier':      req.carrier
			'max_channels': req.max_channels.str()
		}
		headers:    registration_auth_headers(req)
	}
}

pub fn accept_registration(frame WireFrame, expected_token string) !RegistrationResult {
	if frame.kind != .hello {
		return error('relay_registration_unexpected_frame:${frame.kind}')
	}
	validate_frame(frame)!
	node_id := frame.metadata['node_id'] or { return error('relay_registration_missing_node_id') }
	relay_id := frame.metadata['relay_id'] or { return error('relay_registration_missing_relay_id') }
	carrier := frame.metadata['carrier'] or { 'websocket' }
	if carrier != 'websocket' {
		return RegistrationResult{
			accepted: false
			node_id:  node_id
			relay_id: relay_id
			trace_id: frame.trace_id
			error:    'unsupported_carrier:${carrier}'
		}
	}
	if expected_token != '' {
		got := frame.headers['authorization'] or { '' }
		if got != 'Bearer ${expected_token}' {
			return RegistrationResult{
				accepted: false
				node_id:  node_id
				relay_id: relay_id
				trace_id: frame.trace_id
				error:    'unauthorized'
			}
		}
	}
	return RegistrationResult{
		accepted: true
		node_id:  node_id
		relay_id: relay_id
		trace_id: frame.trace_id
	}
}

pub fn registration_ack_frame(result RegistrationResult) WireFrame {
	kind := if result.accepted { WireFrameKind.hello_ack } else { WireFrameKind.error }
	mut metadata := {
		'node_id':  result.node_id
		'relay_id': result.relay_id
	}
	if result.error != '' {
		metadata['error'] = result.error
	}
	if result.retry_after_ms > 0 {
		metadata['retry_after_ms'] = result.retry_after_ms.str()
	}
	return WireFrame{
		version:  wire_version
		kind:     kind
		id:       'relay-ack:${result.node_id}'
		trace_id: result.trace_id
		metadata: metadata
	}
}

fn validate_registration_request(req RegistrationRequest) ! {
	if req.node_id.trim_space() == '' {
		return error('relay_registration_missing_node_id')
	}
	if req.relay_id.trim_space() == '' {
		return error('relay_registration_missing_relay_id')
	}
	if req.carrier.trim_space() == '' {
		return error('relay_registration_missing_carrier')
	}
	if req.trace_id.trim_space() == '' {
		return error('relay_registration_missing_trace_id')
	}
	if req.max_channels <= 0 {
		return error('relay_registration_invalid_max_channels')
	}
}

fn registration_auth_headers(req RegistrationRequest) map[string]string {
	if req.token == '' {
		return map[string]string{}
	}
	return {
		'authorization': 'Bearer ${req.token}'
	}
}
