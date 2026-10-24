module protocol

import upstream.transport

fn value_owner_route() &SessionDispatch {
	return &SessionDispatch{
		provider:   'owner-test'
		retired_fn: fn () bool { return false }
		call_fn:    fn (_ transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
			return transport.WorkerMcpDispatchResponse{}
		}
	}
}

fn test_ensure_session_return_cannot_modify_owned_pending_queue() {
	mut state := McpState{}
	state.ensure_session('session', '', '', '', '')
	assert state.do_queue('session', 'original').queued
	mut held := state.ensure_session('session', '', '', '', '')
	held.pending[0] = 'tampered'
	assert state.sessions['session'].pending == ['original']
}

fn test_dispatch_completion_return_cannot_modify_owned_pending_queue() {
	mut state := McpState{}
	route := value_owner_route()
	state.complete_dispatch_session('session', '', '', '', '', route, false) or { panic(err) }
	assert state.do_queue('session', 'original').queued
	mut held := state.complete_dispatch_session('session', '', '', '', '', route, true) or { panic(err) }
	held.pending[0] = 'tampered'
	assert state.sessions['session'].pending == ['original']
}

fn test_concurrent_generated_session_ids_are_unique() {
	results := chan []string{cap: 16}
	mut workers := []thread{}
	for _ in 0 .. 16 {
		workers << spawn fn [results] () {
			mut ids := []string{cap: 512}
			for _ in 0 .. 512 { ids << Session.generate_id() or { panic(err) } }
			results <- ids
		}()
	}
	mut seen := map[string]bool{}
	for _ in 0 .. 16 {
		ids := <-results
		for id in ids {
			assert id.starts_with('mcp_')
			assert id.len == 52
			seen[id] = true
		}
	}
	workers.wait()
	assert seen.len == 8192
}

fn test_held_session_queue_survives_drop_delete_and_id_reuse() {
	mut state := McpState{ max_pending_messages: 2 }
	state.ensure_session('session', '', '', '', '')
	assert state.do_queue('session', 'first').queued
	mut held := state.ensure_session('session', '', '', '', '')
	assert state.do_queue('session', 'second').queued
	assert state.do_queue('session', 'third').queued
	assert state.sessions['session'].pending == ['second', 'third']
	assert state.stat_pending_dropped_total == 1
	assert held.pending == ['first']
	assert state.delete_session('session')
	state.ensure_session('session', '', '', '', '')
	assert state.do_queue('session', 'replacement').queued
	held.pending[0] = 'old snapshot'
	assert state.sessions['session'].pending == ['replacement']
}
