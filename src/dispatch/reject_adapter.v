module dispatch

pub struct RejectAdapter {
pub:
	name        string
	status      int
	error       string
	error_class string
}

pub fn reject_adapter(id string, status int, error string, error_class string) RejectAdapter {
	return RejectAdapter{
		name:        id
		status:      if status > 0 { status } else { 403 }
		error:       error
		error_class: if error_class != '' { error_class } else { 'rejected' }
	}
}

pub fn (adapter RejectAdapter) id() string {
	return adapter.name
}

pub fn (adapter RejectAdapter) capabilities() Capabilities {
	_ = adapter
	return Capabilities{
		request_response: true
	}
}

pub fn (mut adapter RejectAdapter) warmup(mut services RuntimeServices) ! {
	_ = adapter
	_ = services
}

pub fn (mut adapter RejectAdapter) deliver(mut services RuntimeServices, exchange Exchange) !DeliveryOutcome {
	_ = services
	_ = exchange
	return delivery_failure_outcome(adapter.status, adapter.error, adapter.error_class)
}

pub fn (mut adapter RejectAdapter) close() {
	_ = adapter
}
