module dispatch

pub struct HttpIngressRequest {
pub:
	method         string
	path           string
	query          map[string]string
	headers        map[string]string
	body           string
	remote_addr    string
	request_id     string
	trace_id       string
	exchange_id    string
	ingress        string
	pipeline       string
	created_at_ms  i64
	deadline_at_ms i64
}

pub fn http_request_exchange(req HttpIngressRequest) Exchange {
	exchange_id := if req.exchange_id.trim_space() != '' { req.exchange_id } else { req.request_id }
	return Exchange{
		identity:       ExchangeIdentity{
			id:         exchange_id
			request_id: req.request_id
			trace_id:   req.trace_id
		}
		kind:           .request
		ingress:        req.ingress
		pipeline:       req.pipeline
		created_at_ms:  req.created_at_ms
		deadline_at_ms: req.deadline_at_ms
		headers:        normalized_header_map(req.headers)
		metadata:       {
			'protocol':    'http'
			'remote_addr': req.remote_addr
		}
		payload:        RequestPayload{
			method:      req.method.to_upper()
			path:        req.path
			query:       req.query.clone()
			body:        req.body
			remote_addr: req.remote_addr
		}
	}
}

pub fn normalized_header_map(headers map[string]string) map[string]string {
	mut normalized := map[string]string{}
	for key, value in headers {
		normalized[key.to_lower()] = value
	}
	return normalized
}
