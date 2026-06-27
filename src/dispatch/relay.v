module dispatch

pub struct RelayIngressRequest {
pub:
	relay_id       string
	carrier_id     string
	frame_id       string
	channel_id     string
	session_id     string
	link_id        string
	trace_id       string
	request_id     string
	exchange_id    string
	ingress        string
	pipeline       string
	kind           ExchangeKind = .session_message
	body           string
	metadata       map[string]string
	created_at_ms  i64
	deadline_at_ms i64
}

pub fn relay_ingress_exchange(req RelayIngressRequest) Exchange {
	exchange_id := if req.exchange_id.trim_space() != '' {
		req.exchange_id
	} else if req.frame_id.trim_space() != '' {
		req.frame_id
	} else {
		req.request_id
	}
	ingress := if req.ingress.trim_space() != '' { req.ingress } else { 'relay:${req.relay_id}' }
	mut metadata := req.metadata.clone()
	metadata['protocol'] = 'relay'
	metadata['relay_id'] = req.relay_id
	metadata['carrier_id'] = req.carrier_id
	metadata['frame_id'] = req.frame_id
	metadata['channel_id'] = req.channel_id
	metadata['session_id'] = req.session_id
	metadata['link_id'] = req.link_id
	return Exchange{
		identity:       ExchangeIdentity{
			id:         exchange_id
			request_id: req.request_id
			trace_id:   req.trace_id
		}
		kind:           req.kind
		ingress:        ingress
		pipeline:       req.pipeline
		created_at_ms:  req.created_at_ms
		deadline_at_ms: req.deadline_at_ms
		headers:        map[string]string{}
		metadata:       metadata
		payload:        SessionPayload{
			session_id: req.session_id
			message:    req.body
		}
	}
}
