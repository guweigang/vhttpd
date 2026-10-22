module worker

// A pool only needs an event sink from its host, not the application itself.
pub struct LifecyclePort {
pub:
	emit_fn fn (string, map[string]string) = fn (_kind string, _fields map[string]string) {}
}
