module codex

// ── ProviderRuntime Instance Helpers ──

// normalize_instance normalizes an instance string to its canonical name.
// Empty or "default" become "main"; all others pass through trimmed.
pub fn ProviderRuntime.normalize_instance(instance string) string {
	name := instance.trim_space()
	if name == '' || name == 'default' {
		return 'main'
	}
	return name
}

// for_instance creates a ProviderRuntime for the given instance name, inheriting
// config from the base runtime.
pub fn (base ProviderRuntime) for_instance(instance string) ProviderRuntime {
	resolved := ProviderRuntime.normalize_instance(instance)
	return ProviderRuntime{
		instance:           resolved
		enabled:            base.enabled
		url:                base.url
		model:              base.model
		effort:             base.effort
		cwd:                base.cwd
		approval_policy:    base.approval_policy
		sandbox:            base.sandbox
		reconnect_delay_ms: base.reconnect_delay_ms
		flush_interval_ms:  base.flush_interval_ms
		stream_map:         map[string][]CodexTarget{}
		pending_rpcs:       map[int]PendingRpc{}
		thread_stream_map:  map[string]string{}
		read_fallbacks:     map[string]ReadFallback{}
	}
}

// Runtime snapshots own their mutable containers; native connection references
// remain observations managed by the existing connection/session owner.
pub fn (rt &ProviderRuntime) snapshot_copy() ProviderRuntime {
	mut targets := map[string][]CodexTarget{}
	for stream, entries in rt.stream_map { targets[stream] = entries.clone() }
	return ProviderRuntime{
		...rt
		stream_map:        targets
		pending_rpcs:      rt.pending_rpcs.clone()
		thread_stream_map: rt.thread_stream_map.clone()
		read_fallbacks:    rt.read_fallbacks.clone()
	}
}

// ── CodexState Instance Management ──

pub fn (mut s CodexState) snapshot(instance string) ProviderRuntime {
	resolved := ProviderRuntime.normalize_instance(instance)
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if resolved == 'main' {
		if s.runtime.instance == '' {
			s.runtime.instance = 'main'
		}
		return s.runtime.snapshot_copy()
	}
	if resolved in s.instances {
		rt := s.instances[resolved] or { s.runtime.for_instance(resolved) }
		return rt.snapshot_copy()
	}
	return s.runtime.for_instance(resolved)
}

pub fn (mut s CodexState) update(instance string, rt ProviderRuntime) {
	resolved := ProviderRuntime.normalize_instance(instance)
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	current := if resolved == 'main' { s.runtime } else { s.instances[resolved] or { rt } }
	// A delayed activity update may carry configuration captured before a command.
	next := if current.configuration_generation > rt.configuration_generation {
		ProviderRuntime{
			...rt
			configuration_generation: current.configuration_generation
			enabled:                  current.enabled
			url:                      current.url
			model:                    current.model
			effort:                   current.effort
			cwd:                      current.cwd
			approval_policy:          current.approval_policy
			sandbox:                  current.sandbox
			reconnect_delay_ms:       current.reconnect_delay_ms
			flush_interval_ms:        current.flush_interval_ms
		}
	} else {
		rt
	}
	if resolved == 'main' {
		s.runtime = next.snapshot_copy()
		if s.runtime.instance == '' {
			s.runtime.instance = 'main'
		}
		return
	}
	s.instances[resolved] = next.snapshot_copy()
}

// The marker survives snapshots without granting them a cancellation capability.
// Identity is independent of wire IDs, including explicit runtime replacement.
@[heap]
struct PendingRpcIdentity {}

pub struct RpcRegistration {
	state    &CodexState @[required]
	instance string
	identity &PendingRpcIdentity @[required]
pub:
	id int
}

// Caller holds this state's mutex and publishes rt before unlocking.
pub fn (mut s CodexState) register_rpc_unlocked(instance string, mut rt ProviderRuntime, pending PendingRpc) RpcRegistration {
	identity := &PendingRpcIdentity{}
	id := rt.next_rpc_id()
	rt.remember_pending_rpc(id, PendingRpc{ ...pending, registration: identity, routing_retired: false })
	return RpcRegistration{ state: &s, instance: ProviderRuntime.normalize_instance(instance), identity: identity, id: id }
}

// Check registration admission before using a prepared connection. Native
// connection ownership still guards close/write races after this observation.
pub fn (registration RpcRegistration) is_pending() bool {
	mut s := registration.state
	s.mu.@lock()
	defer { s.mu.unlock() }
	rt := if registration.instance == 'main' {
		s.runtime
	} else {
		s.instances[registration.instance] or { return false }
	}
	pending := rt.pending_rpcs[registration.id] or { return false }
	if pending.routing_retired { return false }
	identity := pending.registration or { return false }
	return voidptr(identity) == voidptr(registration.identity)
}

// A failed send releases only its own pending record. A response, repeated
// cleanup or a replacement using the same wire ID cannot remove a newer record.
pub fn (registration RpcRegistration) cancel() bool {
	mut s := registration.state
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut rt := if registration.instance == 'main' {
		s.runtime
	} else {
		s.instances[registration.instance] or { return false }
	}
	pending := rt.pending_rpcs[registration.id] or { return false }
	identity := pending.registration or { return false }
	if voidptr(identity) != voidptr(registration.identity) { return false }
	rt.pending_rpcs.delete(registration.id)
	if registration.instance == 'main' {
		s.runtime = rt
	} else {
		s.instances[registration.instance] = rt
	}
	return true
}
