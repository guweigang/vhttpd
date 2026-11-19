module codex

fn test_pending_capacity_expiry_and_monotonic_registration() {
	mut state := CodexState{}
	mut rt := ProviderRuntime{}
	for _ in 0 .. pending_rpc_limit { state.register_rpc_unlocked('main', mut rt, PendingRpc{}) }
	assert !rt.can_register_rpcs(1)
	rejected := state.register_rpc_unlocked('main', mut rt, PendingRpc{})
	assert rt.pending_rpcs.len == pending_rpc_limit
	deadline := rt.pending_rpcs[1].expires_at_ms
	assert rt.prune_pending_rpcs(deadline - 1) == 0
	assert rt.prune_pending_rpcs(deadline + pending_rpc_timeout_ms) == pending_rpc_limit
	next := state.register_rpc_unlocked('main', mut rt, PendingRpc{})
	assert next.id > rejected.id
	assert rt.pending_rpcs.len == 1
}

fn test_pending_rejects_oversize_metadata() {
	mut rt := ProviderRuntime{}
	rt.remember_pending_rpc(1, PendingRpc{stream_id: 'x'.repeat(4097)})
	assert rt.pending_rpcs.len == 0
}
