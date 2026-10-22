module main

struct EventDispatchServices {
	emit_fn fn (string, map[string]string) @[required]
	trace   string
}

fn (services EventDispatchServices) trace_id() string { return services.trace }

fn (services EventDispatchServices) emit(event string, fields map[string]string) {
	services.emit_fn(event, fields)
}
