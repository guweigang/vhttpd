module main

import upstream.transport

fn test_worker_backend_error_classifier_preserves_queue_classes() {
	full_status, full_class := transport.classify_worker_backend_error('worker queue full')
	assert full_status == 503
	assert full_class == 'worker_queue_full'

	timeout_status, timeout_class := transport.classify_worker_backend_error('worker queue timeout')
	assert timeout_status == 504
	assert timeout_class == 'worker_queue_timeout'
}
