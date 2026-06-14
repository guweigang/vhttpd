module main

// HttpStats tracks per-request counters for observability.
pub struct HttpStats {
pub mut:
	requests_total      i64
	errors_total        i64
	timeouts_total      i64
	streams_total       i64
	admin_actions_total i64
}

pub fn (mut s HttpStats) inc_requests() {
	s.requests_total++
}

pub fn (mut s HttpStats) inc_errors() {
	s.errors_total++
}

pub fn (mut s HttpStats) inc_timeouts() {
	s.timeouts_total++
}

pub fn (mut s HttpStats) inc_streams() {
	s.streams_total++
}

pub fn (mut s HttpStats) inc_admin_actions() {
	s.admin_actions_total++
}
