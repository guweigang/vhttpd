module dispatch

pub struct ExchangeIdentity {
pub:
	id         string
	request_id string
	trace_id   string
	parent_id  string
}

pub enum ExchangeKind {
	request
	response
	event
	stream_open
	stream_chunk
	stream_end
	session_open
	session_message
	session_close
	error
}

pub struct EmptyPayload {}

pub struct RequestPayload {
pub:
	method      string
	path        string
	query       map[string]string
	body        string
	remote_addr string
}

pub struct ResponsePayload {
pub:
	status int
	body   string
}

pub struct EventPayload {
pub:
	topic    string
	name     string
	data     string
	metadata map[string]string
}

pub struct StreamPayload {
pub:
	session_id string
	chunk      string
	reason     string
}

pub struct SessionPayload {
pub:
	session_id string
	message    string
	rooms      []string
}

pub struct ErrorPayload {
pub:
	message     string
	error_class string
	status      int
}

pub type ExchangePayload = EmptyPayload
	| ErrorPayload
	| EventPayload
	| RequestPayload
	| ResponsePayload
	| SessionPayload
	| StreamPayload

pub struct Exchange {
pub:
	identity       ExchangeIdentity
	kind           ExchangeKind
	ingress        string
	pipeline       string
	created_at_ms  i64
	deadline_at_ms i64
pub mut:
	headers  map[string]string
	metadata map[string]string
	payload  ExchangePayload = EmptyPayload{}
}

pub struct Capabilities {
pub:
	request_response bool
	events           bool
	stream_input     bool
	stream_output    bool
	full_duplex      bool
	sessions         bool
	multiplexing     bool
	cancellation     bool
	backpressure     bool
	replay           bool
}

pub enum TransformActionKind {
	continue_pipeline
	respond
	forward
	fanout
	reject
	drop
}

pub struct TransformAction {
pub:
	kind        TransformActionKind
	target      string
	targets     []string
	status      int
	error       string
	error_class string
}

pub fn continue_pipeline_action() TransformAction {
	return TransformAction{
		kind: .continue_pipeline
	}
}

pub fn respond_action(status int) TransformAction {
	return TransformAction{
		kind:   .respond
		status: status
	}
}

pub fn reject_action(status int, error string, error_class string) TransformAction {
	return TransformAction{
		kind:        .reject
		status:      status
		error:       error
		error_class: error_class
	}
}

pub interface RuntimeServices {
	trace_id() string
	emit(event string, fields map[string]string)
}

pub interface Transformer {
	id() string
	capabilities() Capabilities
mut:
	warmup(mut services RuntimeServices) !
	transform(mut services RuntimeServices, mut exchange Exchange) !TransformAction
	close()
}
