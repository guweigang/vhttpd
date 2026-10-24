module feishu

import sync

@[heap]
struct BridgeStreamGate {
mut:
	mu sync.Mutex
}

pub struct BridgeStreamGateLease {
	gate &BridgeStreamGate @[required]
}

pub fn (lease BridgeStreamGateLease) release() {
	mut gate := lease.gate
	gate.mu.unlock()
}

// Wait outside Feishu/Codex locks. Generation and the original gate are
// captured before waiting; replacement is free to install its own gate.
pub fn (mut s FeishuState) acquire_bridge_stream_gate(message string, stream string, app string, generation string) ?BridgeStreamGateLease {
	s.mu.@lock()
	mut buf := s.buffers[message] or {
		s.mu.unlock()
		return none
	}
	if generation == '' || buf.generation != generation || buf.stream_id != stream
		|| (app != '' && buf.app != app) || buf.bind_pending || buf.failure != none {
		s.mu.unlock()
		return none
	}
	if owner := buf.bridge_owner {
		if !bridge_authority_live(owner) {
			s.mu.unlock()
			return none
		}
	}
	if buf.bridge_gate == none {
		buf.bridge_gate = &BridgeStreamGate{}
		s.buffers[message] = buf
	}
	mut gate := buf.bridge_gate or {
		s.mu.unlock()
		return none
	}
	s.mu.unlock()
	gate.mu.@lock()
	s.mu.@lock()
	active := s.buffers[message] or {
		s.mu.unlock()
		gate.mu.unlock()
		return none
	}
	current := active.bridge_gate or {
		s.mu.unlock()
		gate.mu.unlock()
		return none
	}
	mut valid := voidptr(current) == voidptr(gate) && active.generation == generation
		&& active.stream_id == stream && active.app == buf.app && !active.bind_pending && active.failure == none
	if owner := active.bridge_owner { valid = valid && bridge_authority_live(owner) }
	s.mu.unlock()
	if !valid {
		gate.mu.unlock()
		return none
	}
	return BridgeStreamGateLease{ gate: gate }
}
