module executor

import vjsx

fn test_worker_timeout_wins_once_and_rejects_js_with_timeout_error() ! {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	operation := session.start_host_async_operation(kind: 'worker-deadline')!
	global := ctx.js_global()
	global.set('__deadlinePromise', operation.promise)
	global.free()
	operation.promise.free()
	setup := ctx.eval('__deadlinePromise.catch(error => globalThis.__deadlineError = error.name)')!
	setup.free()
	assert operation.completion.timeout()
	assert operation.cancel.is_cancelled()
	assert !operation.completion.resolve_text('late result')
	assert !operation.completion.cancel('late cancellation')
	assert session.drain_host_async_events()! == 1
	session.pump_until_idle()
	result := ctx.eval('globalThis.__deadlineError')!
	defer { result.free() }
	assert result.to_string() == 'TimeoutError'
	assert session.pending_host_async_operation_count() == 0
}

fn test_worker_timeout_cannot_override_an_accepted_result() ! {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	operation := session.start_host_async_operation(kind: 'completed-before-deadline')!
	defer { operation.promise.free() }
	assert operation.completion.resolve_text('ready')
	assert !operation.completion.timeout()
	assert !operation.cancel.is_cancelled()
	assert session.drain_host_async_events()! == 1
	assert session.pending_host_async_operation_count() == 0
}
