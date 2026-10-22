module executor

fn test_request_stage_snapshot_keeps_fractional_milliseconds_and_other_work() {
	timing := &HttpRequestTiming{ queue_ns: 1000000, vjsx_ns: 6000000, adapter_ns: 2000000, queue_observed: true, vjsx_observed: true, adapter_observed: true }
	stages := timing.snapshot(9700000)
	assert stages.available
	assert stages.queue_ms == 1
	assert stages.vjsx_ms == 6
	assert stages.adapter_ms == 2
	assert stages.other_ms == 0.7
	assert stages.queue_observed && stages.vjsx_observed && stages.adapter_observed
	absent := &HttpRequestTiming{}
	assert !absent.snapshot(100).queue_observed
	assert !absent.snapshot(100).vjsx_observed
}

fn test_dispatch_timing_is_optional_and_request_copies_share_the_explicit_borrow() {
	absent := HttpLogicDispatchRequest{}
	assert absent.timing == none
	mut owned := &HttpRequestTiming{}
	request := HttpLogicDispatchRequest{ timing: owned }
	copied := request
	if mut timing := copied.timing {
		timing.queue_ns = 1000000
		timing.queue_observed = true
	} else {
		assert false
	}
	assert owned.snapshot(2000000).queue_ms == 1
	snapshot := owned.snapshot(2000000)
	owned.queue_ns = 2000000
	assert snapshot.queue_ms == 1
}

fn test_queue_timeout_records_only_explicit_request_timing_and_drains_waiter_count() {
	mut e := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1 })
	// A deliberately occupied, bootstrapped lane forces the queue error path
	// without a JS handler or dependence on HTTP accept scheduling.
	e.state.facade.bootstrapped = true
	e.state.lanes[0].inflight = 1
	defer {
		e.release_lane('lane_0')
		e.close()
	}
	mut host := NoOpAppFacade{}
	mut owned := &HttpRequestTiming{}
	mut failures := 0
	for request in [HttpLogicDispatchRequest{ timing: owned }, HttpLogicDispatchRequest{}] {
		e.dispatch_http_once(mut host, request) or {
			assert err.msg() == 'inproc_vjsx_executor_no_available_lane'
			failures++
			continue
		}
		assert false
	}
	assert failures == 2
	assert owned.queue_observed && owned.queue_ns > 0
	assert !owned.vjsx_observed && owned.vjsx_ns == 0
	assert e.state.http_waiting == 0
	assert e.state.http_queue_timeouts == 2
}
