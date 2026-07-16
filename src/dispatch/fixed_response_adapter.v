module dispatch

pub struct FixedResponseAdapter {
pub:
	name    string
	status  int
	headers map[string]string
	body    string
}

pub fn fixed_response_adapter(id string, status int, headers map[string]string, body string) FixedResponseAdapter {
	return FixedResponseAdapter{
		name:    id
		status:  if status > 0 { status } else { 200 }
		headers: headers.clone()
		body:    body
	}
}

pub fn (adapter FixedResponseAdapter) id() string {
	return adapter.name
}

pub fn (adapter FixedResponseAdapter) capabilities() Capabilities {
	_ = adapter
	return Capabilities{
		request_response: true
	}
}

pub fn (mut adapter FixedResponseAdapter) warmup(mut services RuntimeServices) ! {
	_ = adapter
	_ = services
}

pub fn (mut adapter FixedResponseAdapter) deliver(mut services RuntimeServices, exchange Exchange) !DeliveryOutcome {
	_ = services
	_ = exchange
	return response_outcome(adapter.status, adapter.headers, adapter.body)
}

pub fn (mut adapter FixedResponseAdapter) close() {
	_ = adapter
}
