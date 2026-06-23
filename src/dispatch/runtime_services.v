module dispatch

pub struct NoOpRuntimeServices {
pub:
	trace string
}

pub fn (services NoOpRuntimeServices) trace_id() string {
	return services.trace
}

pub fn (services NoOpRuntimeServices) emit(event string, fields map[string]string) {
	_ = services
	_ = event
	_ = fields
}
