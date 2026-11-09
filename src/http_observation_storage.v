module main

import executor

// Mutable listener-owned counters. The public DTO owns a slice only when an
// admin reader takes a snapshot, rather than allocating four slices per request.
struct HttpObservedMetrics {
	requests_total      i64
	errors_total        i64
	client_errors_total i64
	server_errors_total i64
	timeouts_total      i64
	duration_sum_ms     i64
	duration_count      i64
	duration_max_ms     i64
	duration_buckets    [9]i64
	last_status         int
	last_completed_unix i64
}

fn (metrics HttpObservedMetrics) snapshot() executor.AdminHttpMetrics {
	return executor.AdminHttpMetrics{
		requests_total:      metrics.requests_total
		errors_total:        metrics.errors_total
		client_errors_total: metrics.client_errors_total
		server_errors_total: metrics.server_errors_total
		timeouts_total:      metrics.timeouts_total
		duration_sum_ms:     metrics.duration_sum_ms
		duration_count:      metrics.duration_count
		duration_max_ms:     metrics.duration_max_ms
		duration_buckets:    metrics.duration_buckets[..].clone()
		last_status:         metrics.last_status
		last_completed_unix: metrics.last_completed_unix
	}
}

// Written only under ControlPlaneRuntime.mu. Replacing a slot releases all of
// its old references; chronological copying happens only for admin reads.
struct HttpObservationRing {
mut:
	entries []executor.AdminHttpObservationError
	next    int
}

fn (mut ring HttpObservationRing) append(entry executor.AdminHttpObservationError, limit int) {
	if ring.entries.len == 0 {
		ring.entries = []executor.AdminHttpObservationError{cap: limit}
	}
	if ring.entries.len < limit {
		ring.entries << entry
		return
	}
	ring.entries[ring.next] = entry
	ring.next = (ring.next + 1) % limit
}

fn (ring &HttpObservationRing) snapshot() []executor.AdminHttpObservationError {
	mut entries := []executor.AdminHttpObservationError{cap: ring.entries.len}
	for i in 0 .. ring.entries.len {
		entries << ring.entries[(ring.next + i) % ring.entries.len]
	}
	return entries
}
