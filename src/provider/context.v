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
	snapshot fn () string = unsafe { nil }
	// start performs provider-specific startup (may launch goroutines, etc).
	start    fn () ! = unsafe { nil }
	// stop performs provider-specific shutdown.
	stop     fn () ! = unsafe { nil }
	// emit dispatches a structured event.
	emit     fn (string, map[string]string) = unsafe { nil }
}
