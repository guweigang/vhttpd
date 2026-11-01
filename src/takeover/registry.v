module takeover

import relay
import sync

// Ephemeral, attachment-owned account selection. Never persisted or restored
// on reconnect: a new connection requires an explicit new start operation.
pub struct Lease {
pub:
	id         string
	app_id     string
	accounts   []string
	relay_id   string
	route      string
	expires_ms i64
	binding    relay.CarrierDispatchPlan
}

@[heap]
pub struct Registry {
mut:
	mu        sync.Mutex
	lease     ?Lease
	in_flight int
}

pub fn (mut r Registry) start(lease Lease, now i64) ! {
	if lease.id == '' || lease.app_id == '' || lease.accounts.len == 0 || lease.accounts.len > 16 || lease.accounts.any(it == '' || it.len > 128) || lease.expires_ms <= now || lease.expires_ms > now + 900000 || !lease.binding.is_current() {
		return error('takeover_invalid_lease')
	}
	r.mu.@lock()
	defer { r.mu.unlock() }
	if old := r.lease {
		if old.expires_ms > now && old.binding.is_current() {
			return error('takeover_already_active')
		}
	}
	r.lease = lease
}

pub fn (mut r Registry) status(now i64) ?Lease {
	r.mu.@lock()
	defer { r.mu.unlock() }
	lease := r.lease or { return none }
	if lease.expires_ms <= now || !lease.binding.is_current() {
		r.lease = none
		return none
	}
	return lease
}

pub fn (mut r Registry) stop(id string, carrier_id string) ! {
	r.mu.@lock()
	defer { r.mu.unlock() }
	lease := r.lease or { return }
	if lease.id != id || lease.binding.carrier_id != carrier_id {
		return error('takeover_owner_changed')
	}
	r.lease = none
}

// No match means remote execution is safe. Once admitted, errors must never
// turn into a remote fallback, including failures before a send is confirmed.
pub fn (mut r Registry) admit(app_id string, account string, now i64) !Lease {
	r.mu.@lock()
	defer { r.mu.unlock() }
	lease := r.lease or { return Lease{} }
	if lease.expires_ms <= now || !lease.binding.is_current() {
		r.lease = none
		return Lease{}
	}
	if lease.app_id != app_id || account !in lease.accounts { return Lease{} }
	if r.in_flight >= 8 { return error('takeover_busy') }
	r.in_flight++
	return lease
}

pub fn (mut r Registry) finish() {
	r.mu.@lock()
	r.in_flight--
	r.mu.unlock()
}

// The receiver also bounds work independently of the sending hub.
pub fn (mut r Registry) begin_execution() ! {
	r.mu.@lock()
	defer { r.mu.unlock() }
	if r.in_flight >= 8 { return error('takeover_busy') }
	r.in_flight++
}

pub fn (mut r Registry) executions() int {
	r.mu.@lock()
	defer { r.mu.unlock() }
	return r.in_flight
}
