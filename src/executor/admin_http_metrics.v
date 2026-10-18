module executor

// Handler completion latency, not socket transmission or network latency.
pub struct AdminHttpMetrics {
pub:
	requests_total i64
	errors_total i64
	client_errors_total i64
	server_errors_total i64
	timeouts_total i64
	duration_sum_ms i64
	duration_count i64
	duration_max_ms i64
	duration_buckets []i64
	last_status int
	last_completed_unix i64
}

pub struct AdminHttpRouteMetrics {
pub:
	pipeline_id string
	metrics AdminHttpMetrics
}

pub struct AdminHttpObservationError {
pub:
	stages AdminHttpStages
	pipeline_id string
	observation_id string
	method string
	status int
	duration_ms i64
	at_unix i64
}

pub struct AdminHttpTimePoint {
pub:
	at_unix i64
	span_seconds i64
	metrics AdminHttpMetrics
}

pub struct AdminHttpListenerWindow {
pub:
	listener_id string
	metrics AdminHttpMetrics
	routes []AdminHttpRouteMetrics
}

pub struct AdminHttpTrafficWindow {
pub:
	at_unix i64
	start_unix i64
	window_seconds int
	bucket_seconds int = 10
	listener string
	pipeline string
	route_filtered bool
	listeners []AdminHttpListenerWindow
	metrics AdminHttpMetrics
	series []AdminHttpTimePoint
}

pub struct AdminHttpRequestDetail {
pub:
	request AdminHttpObservationError
	log_line string
}

pub struct AdminHttpRequestDetails {
pub:
	at_unix i64
	listener string
	pipeline string
	window_seconds int
	min_ms i64
	retained int
	limit int = 50
	requests []AdminHttpRequestDetail
}
