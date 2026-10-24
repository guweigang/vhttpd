module worker

import net.unix

struct ConnectorAttempts {
mut:
	count int
}

fn test_connector_does_not_retry_queue_backpressure() {
	for queue_error in ['worker queue full', 'worker queue timeout'] {
		mut attempts := &ConnectorAttempts{}
		ctx := ConnectorContext{
			connect_fn:       unix.connect_stream
			select_socket_fn: fn [mut attempts, queue_error] () !string {
				attempts.count++
				return error(queue_error)
			}
			release_fn:       fn (_socket string) {}
			emit_fn:          fn (_kind string, _fields map[string]string) {}
		}
		if _ := ConnectorRuntime.socket_with_retry(ctx) {
			assert false
		} else {
			assert err.msg() == queue_error
		}
		assert attempts.count == 1
	}
}
