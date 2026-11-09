module main

import executor

fn test_http_observation_counts_errors_latency_and_bounds_retention() {
	mut observations := HttpObservations{}
	observations.record('hello', 'GET', 200, 10, 'ok', 1)
	observations.record('hello', 'GET', 404, 50, 'not-found', 2)
	observations.record('slow', 'POST', 504, 5010, 'timeout', 3)
	assert observations.total.requests_total == 3
	assert observations.total.errors_total == 2
	assert observations.total.client_errors_total == 1
	assert observations.total.server_errors_total == 1
	assert observations.total.timeouts_total == 1
	assert observations.total.duration_sum_ms == 5070
	assert observations.total.duration_max_ms == 5010
	assert observations.total.snapshot().duration_buckets == [i64(0), 0, 1, 2, 2, 2, 2, 2, 3]
	assert observations.routes['hello'].requests_total == 2
	for i in 0 .. 600 { observations.record('route-${i}', 'GET', 500, 1, 'error-${i}', i) }
	assert observations.routes.len <= 513
	assert observations.errors.entries.len == 20
	assert observations.errors.snapshot().last().observation_id == 'error-599'
	assert observations.routes['@overflow'].requests_total > 0
}

fn test_http_observation_ring_wraps_and_snapshots_own_their_slots() {
	mut ring := HttpObservationRing{}
	for i in 0 .. 12 {
		ring.append(executor.AdminHttpObservationError{observation_id: '${i}'}, 3)
	}
	before := ring.snapshot()
	assert before.map(it.observation_id) == ['9', '10', '11']
	ring.append(executor.AdminHttpObservationError{observation_id: '12'}, 3)
	assert ring.entries.len == 3
	assert ring.snapshot().map(it.observation_id) == ['10', '11', '12']
	assert before.map(it.observation_id) == ['9', '10', '11']
	assert HttpObservationRing{}.snapshot().len == 0
}

fn test_http_metric_snapshot_does_not_alias_live_histogram() {
	first := http_metrics_record(HttpObservedMetrics{}, 200, 1, 100)
	before := first.snapshot()
	second := http_metrics_record(first, 500, 2, 101)
	assert first.duration_buckets[8] == 1
	assert before.duration_buckets[8] == 1
	assert second.duration_buckets[8] == 2
	assert second.errors_total == 1
}

fn test_http_observation_formats_only_enabled_completion_logs() {
	assert !http_observation_should_log(200, 10, .warn)
	assert http_observation_should_log(200, 10, .info)
	assert !http_observation_should_log(200, 0, .info)
	assert http_observation_should_log(500, 0, .warn)
	assert !http_observation_should_log(500, 10, .error)
	assert !http_observation_should_log(500, 10, .disabled)
}
