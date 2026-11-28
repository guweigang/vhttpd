module feishu

import sync
import strconv

struct FragmentSet {
mut:
	parts   map[int][]u8
	count   int
	bytes   int
	expires i64
}

@[heap]
pub struct FragmentOwner {
mut:
	mu      sync.Mutex
	pending map[string]FragmentSet
}

pub struct FragmentResult {
pub:
	ready bool
	frame RuntimeProtoFrame
}

// Feishu fragments are transport frames, indexed from zero. Bound both memory
// and lifetime; never decode event contents or deliver an incomplete JSON body.
pub fn (mut owner FragmentOwner) merge(instance string, frame RuntimeProtoFrame, now i64) !FragmentResult {
	headers := RuntimeProtoHeader.to_map(frame.headers)
	sum_raw := headers['sum'] or { '' }
	if sum_raw == '' { return FragmentResult{ ready: true, frame: frame } }
	sum := strconv.atoi(sum_raw) or { return error('invalid fragment count') }
	if sum < 1 || sum > 128 { return error('fragment count out of bounds') }
	if sum == 1 { return FragmentResult{ ready: true, frame: frame } }
	seq := strconv.atoi(headers['seq'] or { '' }) or { return error('invalid fragment sequence') }
	id := headers['message_id'] or { '' }
	if seq < 0 || seq >= sum || id.len == 0 || id.len > 256 {
		return error('invalid fragment metadata')
	}
	key := '${instance.len}:${instance}${id}'
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	for name, entry in owner.pending {
		if entry.expires <= now { owner.pending.delete(name) }
	}
	if key !in owner.pending && owner.pending.len >= 64 {
		return error('fragment capacity exceeded')
	}
	mut entry := owner.pending[key] or { FragmentSet{ count: sum, expires: now + 60000 } }
	if entry.count != sum {
		owner.pending.delete(key)
		return error('fragment count changed')
	}
	if old := entry.parts[seq] {
		if old != frame.payload {
			owner.pending.delete(key)
			return error('conflicting duplicate fragment')
		}
	} else {
		entry.bytes += frame.payload.len
		if entry.bytes > 1024 * 1024 {
			owner.pending.delete(key)
			return error('fragment payload exceeds limit')
		}
		entry.parts[seq] = frame.payload.clone()
	}
	if entry.parts.len != sum {
		owner.pending[key] = entry
		return FragmentResult{}
	}
	mut payload := []u8{cap: entry.bytes}
	for idx in 0 .. sum { payload << entry.parts[idx] }
	owner.pending.delete(key)
	return FragmentResult{ ready: true, frame: RuntimeProtoFrame{ ...frame, payload: payload } }
}

// A reconnect must not assemble an old connection's incomplete event.
pub fn (mut owner FragmentOwner) clear(instance string) {
	prefix := '${instance.len}:${instance}'
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	for key, _ in owner.pending { if key.starts_with(prefix) { owner.pending.delete(key) } }
}
