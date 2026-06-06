module transport

pub fn classify_worker_backend_error(err_msg string) (int, string) {
	msg := err_msg.to_lower()
	if msg.contains('all workers busy') {
		return 503, 'worker_pool_exhausted'
	}
	if msg.contains('worker queue full') {
		return 503, 'worker_queue_full'
	}
	if msg.contains('worker queue timeout') {
		return 504, 'worker_queue_timeout'
	}
	if msg.contains('timed out') || msg.contains('timeout') {
		return 504, 'timeout'
	}
	return 502, 'transport_error'
}
