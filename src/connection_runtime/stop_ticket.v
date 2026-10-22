module connection_runtime

import sync

// The ticket retains the exact registry, prefix and accepted runs selected by
// one stop request. Waiters share its single admission-release responsibility.
@[heap]
pub struct StopTicket {
	registry &Registry @[required]
	prefix   string
	runs     []&Run
mut:
	mu        sync.Mutex
	completed bool
}

pub fn (mut ticket StopTicket) finished() bool {
	ticket.mu.@lock()
	defer { ticket.mu.unlock() }
	return ticket.completed
}

pub fn (mut ticket StopTicket) wait() {
	// No registry or ticket lock is held while callbacks finish their cleanup.
	for mut run in ticket.runs { run.wait_finished() }
	ticket.mu.@lock()
	defer { ticket.mu.unlock() }
	if ticket.completed { return }
	mut registry := ticket.registry
	registry.mu.@lock()
	remaining := registry.blocked[ticket.prefix] - 1
	if remaining == 0 {
		registry.blocked.delete(ticket.prefix)
	} else {
		registry.blocked[ticket.prefix] = remaining
	}
	registry.mu.unlock()
	ticket.completed = true
}
