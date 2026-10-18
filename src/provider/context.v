module provider

// RuntimeContext carries closures that bridge the provider sub-module
// to the main App. Each closure captures what it needs from App,
// so provider/ never imports main.
//
// One RuntimeContext is built per provider in main, capturing
// provider-specific snapshot/start/stop logic.
pub struct RuntimeContext {
pub:
	// snapshot returns a JSON string of this provider's runtime state.
	snapshot fn () string @[required]
	// start performs provider-specific startup (may launch goroutines, etc).
	start fn () ! @[required]
	// stop performs provider-specific shutdown.
	stop fn () ! @[required]
	// emit dispatches a structured event.
	emit fn (string, map[string]string) @[required]
}

// Select explicitly when a provider intentionally has no lifecycle or events.
// Runtime contexts used by active providers must inject their real callbacks.
pub fn RuntimeContext.noop() RuntimeContext {
	return RuntimeContext{
		snapshot: noop_snapshot
		start:    noop_lifecycle
		stop:     noop_lifecycle
		emit:     noop_emit
	}
}

fn noop_snapshot() string { return '{}' }

fn noop_lifecycle() ! {}

fn noop_emit(_kind string, _fields map[string]string) {}
