module process_runtime

import time

fn test_shutdown_has_exactly_one_concurrent_claimant() {
	mut owner := &ShutdownOwner{}
	mut calls := []thread bool{}
	for _ in 0 .. 16 { calls << spawn owner.claim() }
	mut winners := 0
	for call in calls { if call.wait() { winners++ } }
	assert winners == 1
	owner.finish('')
	owner.wait_stopped() or { panic(err) }
	assert !owner.claim()
}

fn test_shutdown_waiters_join_completion_without_repeating_cleanup() {
	mut owner := &ShutdownOwner{}
	assert owner.claim()
	done := chan bool{cap: 4}
	for _ in 0 .. 4 {
		spawn fn [mut owner, done] () {
			owner.wait_stopped() or { panic(err) }
			done <- true
		}()
	}
	select {
		_ := <-done {
			panic('shutdown completed early')
		}
		10 * time.millisecond {
		}
	}
	owner.finish('')
	for _ in 0 .. 4 {
		select {
			_ := <-done {
			}
			time.second {
				panic('shutdown waiter stuck')
			}
		}
	}
}

fn test_shutdown_failure_is_terminal_and_repeated_completion_cannot_hide_it() {
	mut owner := &ShutdownOwner{}
	assert owner.claim()
	owner.finish('drain failed')
	owner.finish('')
	assert !owner.claim()
	mut failed := false
	owner.wait_stopped() or {
		assert err.msg() == 'drain failed'
		failed = true
	}
	assert failed
}

fn test_unstarted_shutdown_wait_reports_explicit_error() {
	mut owner := &ShutdownOwner{}
	mut failed := false
	owner.wait_stopped() or {
		assert err.msg() == 'app_shutdown_not_started'
		failed = true
	}
	assert failed
}

fn test_startup_admission_closes_on_claim_and_join_waits_for_accepted_starts() {
	mut owner := &ShutdownOwner{}
	assert owner.begin_start()
	assert owner.claim()
	assert !owner.begin_start()
	done := chan bool{cap: 1}
	spawn fn [mut owner, done] () {
		owner.wait_started()
		done <- true
	}()
	select {
		_ := <-done {
			panic('startup not joined')
		}
		10 * time.millisecond {
		}
	}
	owner.end_start()
	select {
		_ := <-done {
		}
		time.second {
			panic('startup join stuck')
		}
	}
	owner.finish('')
	assert !owner.begin_start()
}
