module dispatch

pub struct IngressDescriptor {
pub:
	id           string
	capabilities Capabilities
}

pub enum DeliveryOutcomeKind {
	response
	accepted_event
	stream_plan
	session_plan
	relay_delivery
	failure
}

pub struct DeliveryOutcome {
pub:
	kind        DeliveryOutcomeKind
	status      int
	headers     map[string]string
	body        string
	target      string
	error       string
	error_class string
	metadata    map[string]string
}

pub fn response_outcome(status int, headers map[string]string, body string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:    .response
		status:  status
		headers: headers.clone()
		body:    body
	}
}

pub fn accepted_event_outcome(metadata map[string]string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:     .accepted_event
		status:   202
		metadata: metadata.clone()
	}
}

pub fn delivery_failure_outcome(status int, error string, error_class string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:        .failure
		status:      status
		error:       error
		error_class: error_class
	}
}

pub interface EgressAdapter {
	id() string
	capabilities() Capabilities
mut:
	warmup(mut services RuntimeServices) !
	deliver(mut services RuntimeServices, exchange Exchange) !DeliveryOutcome
	close()
}
