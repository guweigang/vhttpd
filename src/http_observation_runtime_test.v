module main

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
	assert observations.total.duration_buckets == [i64(0), 0, 1, 2, 2, 2, 2, 2, 3]
	assert observations.routes['hello'].requests_total == 2
	for i in 0 .. 600 { observations.record('route-${i}', 'GET', 500, 1, 'error-${i}', i) }
	assert observations.routes.len <= 513
	assert observations.errors.len == 20
	assert observations.errors.last().observation_id == 'error-599'
	assert observations.routes['@overflow'].requests_total > 0
}
