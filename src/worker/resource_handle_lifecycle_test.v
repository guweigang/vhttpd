module worker

import upstream.transport

fn test_managed_worker_pool_stop_clears_owned_slots_and_is_repeatable() {
	proc := transport.ManagedWorker.launch_process('exec sleep 30', {}, '') or { panic(err) }
	mut workers := [transport.ManagedWorker{ proc: proc }, transport.ManagedWorker{}]
	transport.ManagedWorkerPool.stop(mut workers)
	assert workers[0].proc == none
	assert workers[1].proc == none
	assert !workers[0].process_alive()
	transport.ManagedWorkerPool.stop(mut workers)
}

fn test_unstarted_worker_slot_has_no_process_and_can_be_stopped() {
	mut slot := transport.ManagedWorker.build_slot(0, 'test-worker', {}, '/tmp/unstarted.sock', 1) or { panic(err) }
	assert slot.proc == none
	assert !slot.process_alive()
	assert !slot.process_exited()
	slot.stop()
	assert slot.proc == none
}
