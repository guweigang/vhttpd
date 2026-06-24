module dispatch

pub struct IngressDescriptor {
pub:
	id           string
	capabilities Capabilities
}

pub struct AdapterDescriptor {
pub:
	id           string
	kind         string
	capabilities Capabilities
	terminal     bool
}

pub enum DeliveryOutcomeKind {
	response
	file
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
	path        string
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

pub fn outcome_with_metadata(outcome DeliveryOutcome, metadata map[string]string) DeliveryOutcome {
	return DeliveryOutcome{
		...outcome
		metadata: metadata.clone()
	}
}

pub fn file_outcome(path string, headers map[string]string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:    .file
		status:  200
		headers: headers.clone()
		path:    path
	}
}

pub fn accepted_event_outcome(metadata map[string]string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:     .accepted_event
		status:   202
		metadata: metadata.clone()
	}
}

pub fn stream_plan_outcome(target string, headers map[string]string, metadata map[string]string) DeliveryOutcome {
	return stream_plan_outcome_with_status(0, target, headers, metadata)
}

pub fn stream_plan_outcome_with_status(status int, target string, headers map[string]string, metadata map[string]string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:     .stream_plan
		status:   status
		headers:  headers.clone()
		target:   target
		metadata: metadata.clone()
	}
}

pub fn session_plan_outcome(target string, headers map[string]string, metadata map[string]string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:     .session_plan
		headers:  headers.clone()
		target:   target
		metadata: metadata.clone()
	}
}

pub fn relay_delivery_outcome(target string, metadata map[string]string) DeliveryOutcome {
	return DeliveryOutcome{
		kind:     .relay_delivery
		target:   target
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
