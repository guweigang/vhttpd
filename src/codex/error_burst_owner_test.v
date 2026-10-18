module codex

import connection_runtime
import time

fn burst_job(mut owner ErrorBurstOwner, mut registry connection_runtime.Registry, instance string, stream string, payload string) &ErrorBurstJob {
	return owner.enqueue(mut registry, instance, stream, payload) or { panic('burst not reserved') }
}

fn test_burst_aggregation_normalizes_instances_deduplicates_and_takes_once() {
	mut owner := &ErrorBurstOwner{}
	mut registry := &connection_runtime.Registry{}
	job := burst_job(mut owner, mut registry, 'default', 's', 'one')
	assert owner.enqueue(mut registry, 'main', 's', 'two') == none
	assert owner.enqueue(mut registry, '', 's', 'one') == none
	assert job.take() == ['one', 'two']
	assert job.take().len == 0
	job.finish()
	job.finish()
	assert owner.pending.len == 0
}

fn test_stale_timer_and_finalizer_preserve_replacement_burst() {
	mut owner := &ErrorBurstOwner{}
	mut registry := &connection_runtime.Registry{}
	old := burst_job(mut owner, mut registry, 'main', 's', 'old')
	assert old.take() == ['old']
	next := burst_job(mut owner, mut registry, 'main', 's', 'new')
	assert old.take().len == 0
	old.finish()
	old.finish()
	assert next.take() == ['new']
	next.finish()
}

fn test_instance_stream_keys_and_shared_registry_owner_keys_do_not_collide() {
	mut owner := &ErrorBurstOwner{}
	mut other := &ErrorBurstOwner{}
	mut registry := &connection_runtime.Registry{}
	one := burst_job(mut owner, mut registry, 'a', 'bc', 'one')
	two := burst_job(mut owner, mut registry, 'ab', 'c', 'two')
	three := burst_job(mut other, mut registry, 'a', 'bc', 'three')
	assert one.take() == ['one']
	assert two.take() == ['two']
	assert three.take() == ['three']
	one.finish()
	two.finish()
	three.finish()
}

fn test_pause_cancels_reserved_unstarted_job_and_waits_for_release() {
	mut owner := &ErrorBurstOwner{}
	mut registry := &connection_runtime.Registry{}
	job := burst_job(mut owner, mut registry, 'main', 's', 'old')
	mut stopped := registry.request_pause('codex/')
	assert !job.wait(time.hour)
	assert job.take().len == 0
	assert owner.enqueue(mut registry, 'main', 's', 'late') == none
	assert !registry.resume_prefix('codex/')
	done := chan bool{cap: 1}
	spawn fn [mut registry, mut stopped, done] () {
		stopped.wait()
		done <- true
	}()
	select {
		_ := <-done {
			panic('unstarted job was not joined')
		}
		20 * time.millisecond {
		}
	}
	job.finish()
	select {
		_ := <-done {
		}
		time.second {
			panic('pause did not finish')
		}
	}
	assert registry.resume_prefix('codex/')
	next := burst_job(mut owner, mut registry, 'main', 's', 'new')
	assert job.take().len == 0
	job.finish()
	assert next.take() == ['new']
	next.finish()
}

fn test_pause_waits_for_already_claimed_dispatch() {
	mut owner := &ErrorBurstOwner{}
	mut registry := &connection_runtime.Registry{}
	job := burst_job(mut owner, mut registry, 'main', 's', 'old')
	assert job.take() == ['old']
	mut stopped := registry.request_pause('codex/')
	assert !stopped.finished()
	assert !registry.resume_prefix('codex/')
	job.finish()
	stopped.wait()
	assert registry.resume_prefix('codex/')
}

fn test_shutdown_cancels_long_waiters_and_permanently_closes_admission() {
	mut owner := &ErrorBurstOwner{}
	mut registry := &connection_runtime.Registry{}
	done := chan bool{cap: 32}
	for i in 0 .. 32 {
		job := burst_job(mut owner, mut registry, 'main', 's${i}', 'error')
		spawn fn [job, done] () {
			defer { job.finish() }
			assert !job.wait(time.hour)
			assert job.take().len == 0
			done <- true
		}()
	}
	mut stopped := registry.request_shutdown()
	for mut run in stopped { run.wait_finished() }
	for _ in 0 .. 32 { _ := <-done }
	assert owner.pending.len == 0
	assert owner.enqueue(mut registry, 'main', 'new', 'error') == none
	assert !registry.resume_prefix('codex/')
}

fn test_concurrent_producers_keep_all_unique_errors_in_one_burst() {
	mut owner := &ErrorBurstOwner{}
	mut registry := &connection_runtime.Registry{}
	job := burst_job(mut owner, mut registry, 'main', 's', 'initial')
	done := chan bool{cap: 32}
	for i in 0 .. 32 {
		spawn fn [mut owner, mut registry, i, done] () {
			assert owner.enqueue(mut registry, 'main', 's', 'e${i}') == none
			assert owner.enqueue(mut registry, 'main', 's', 'e${i}') == none
			done <- true
		}()
	}
	for _ in 0 .. 32 { _ := <-done }
	messages := job.take()
	assert messages.len == 33
	for i in 0 .. 32 {
		assert 'e${i}' in messages
	}
	job.finish()
}
