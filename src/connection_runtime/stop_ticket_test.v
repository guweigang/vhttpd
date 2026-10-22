module connection_runtime

import time

fn ticket_wait(mut ticket StopTicket, done chan bool) {
	ticket.wait()
	done <- true
}

fn ticket_await(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('stop ticket did not finish')
		}
	}
}

fn test_completed_stop_prefixes_do_not_accumulate_zero_count_entries() {
	mut registry := Registry{}
	for index in 0 .. 1000 { registry.stop_prefix('instance_${index}/') }
	assert registry.blocked.len == 0
	assert registry.paused.len == 0
	mut run := registry.reserve('instance_999/new') or { panic('completed stop still blocks admission') }
	registry.release('instance_999/new', mut run)
}

fn test_repeated_ticket_wait_cannot_release_a_later_stop_scope() {
	mut registry := Registry{}
	mut first := registry.request_pause('feishu/')
	assert !first.finished()
	first.wait()
	assert first.finished()
	assert registry.blocked.len == 0
	assert registry.reserve('feishu/paused') == none
	assert registry.resume_prefix('feishu/')
	mut run := registry.reserve('feishu/old') or { panic('resume failed') }
	mut later := registry.request_pause('feishu/')
	first.wait()
	first.wait()
	assert !later.finished()
	assert registry.blocked['feishu/'] == 1
	assert !registry.resume_prefix('feishu/')
	assert registry.reserve('feishu/new') == none
	registry.release('feishu/old', mut run)
	later.wait()
	assert registry.blocked.len == 0
	assert registry.resume_prefix('feishu/')
}

fn test_concurrent_waiters_share_one_release_without_unblocking_other_tickets() {
	mut registry := &Registry{}
	mut run := registry.reserve('codex/main') or { panic('no run') }
	mut first := registry.request_pause('codex/')
	mut second := registry.request_pause('codex/')
	done := chan bool{cap: 8}
	for _ in 0 .. 8 { spawn ticket_wait(mut first, done) }
	assert !first.finished()
	assert !second.finished()
	assert !registry.resume_prefix('codex/')
	registry.release('codex/main', mut run)
	for _ in 0 .. 8 { ticket_await(done) }
	assert first.finished()
	assert registry.blocked['codex/'] == 1
	assert !registry.resume_prefix('codex/')
	second.wait()
	assert second.finished()
	assert registry.blocked.len == 0
	assert registry.resume_prefix('codex/')
}

fn test_nested_stop_tickets_keep_overlapping_prefixes_blocked_until_both_finish() {
	mut registry := Registry{}
	mut run := registry.reserve('feishu/app/session') or { panic('no run') }
	mut broad := registry.request_stops('feishu/', false)
	mut narrow := registry.request_pause('feishu/app/')
	registry.release('feishu/app/session', mut run)
	narrow.wait()
	assert !registry.resume_prefix('feishu/app/')
	assert registry.reserve('feishu/other') == none
	mut unrelated := registry.reserve('codex/main') or { panic('unrelated prefix blocked') }
	registry.release('codex/main', mut unrelated)
	broad.wait()
	assert registry.blocked.len == 0
	assert registry.reserve('feishu/app/new') == none
	assert registry.resume_prefix('feishu/app/')
	mut next := registry.reserve('feishu/app/new') or { panic('nested pause could not resume') }
	registry.release('feishu/app/new', mut next)
}

fn test_ticket_keeps_its_original_registry_and_cannot_resume_terminal_shutdown() {
	mut first := Registry{}
	mut other := Registry{}
	mut stopped := first.request_pause('shared/')
	mut other_stopped := other.request_pause('shared/')
	first.request_shutdown()
	stopped.wait()
	stopped.wait()
	assert first.blocked.len == 0
	assert !first.resume_prefix('shared/')
	assert other.blocked['shared/'] == 1
	assert !other.resume_prefix('shared/')
	other_stopped.wait()
	assert other.blocked.len == 0
	assert other.resume_prefix('shared/')
}
