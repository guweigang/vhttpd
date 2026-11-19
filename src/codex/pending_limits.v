module codex

import time

pub const pending_rpc_limit = 1024
pub const pending_rpc_timeout_ms = i64(120000)

pub fn (mut rt ProviderRuntime) prune_pending_rpcs(now i64) int {
	mut removed := 0
	for id, pending in rt.pending_rpcs {
		if pending.expires_at_ms > 0 && pending.expires_at_ms <= now {
			rt.pending_rpcs.delete(id)
			removed++
		}
	}
	return removed
}

pub fn (mut rt ProviderRuntime) can_register_rpcs(count int) bool {
	rt.prune_pending_rpcs(time.now().unix_milli())
	return count > 0 && rt.pending_rpcs.len <= pending_rpc_limit - count
}
