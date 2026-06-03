module stats

// HttpStats tracks per-request counters for observability.
pub struct HttpStats {
pub mut:
	requests_total       i64
	errors_total         i64
	timeouts_total       i64
	streams_total        i64
	admin_actions_total  i64
}

// inc_requests increments the total request counter.
pub fn (mut s HttpStats) inc_requests() {
	s.requests_total++
}

// inc_errors increments the error (status >= 400) counter.
pub fn (mut s HttpStats) inc_errors() {
	s.errors_total++
}

// inc_timeouts increments the timeout counter.
pub fn (mut s HttpStats) inc_timeouts() {
	s.timeouts_total++
}

// inc_streams increments the stream response counter.
pub fn (mut s HttpStats) inc_streams() {
	s.streams_total++
}

// inc_admin_actions increments the admin action counter.
pub fn (mut s HttpStats) inc_admin_actions() {
	s.admin_actions_total++
}
