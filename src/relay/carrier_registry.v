module relay

import sync

// Copies retain one synchronized registry; immutable bindings identify one
// attachment even if its relay and carrier IDs are reused after replacement.
pub struct CarrierRegistry {
	owner &CarrierRegistryOwner = &CarrierRegistryOwner{}
}

@[heap]
struct CarrierRegistryOwner {
mut:
	mu       sync.Mutex
	bindings map[string]&CarrierBinding
}

@[heap]
pub struct CarrierBinding {
pub:
	relay_id   string @[required]
	carrier_id string @[required]
}

pub fn new_carrier_registry() CarrierRegistry { return CarrierRegistry{} }

pub fn (mut registry CarrierRegistry) register(relay_id string, carrier_id string) ! {
	registry.bind(relay_id, carrier_id)!
}

pub fn (mut registry CarrierRegistry) bind(relay_id string, carrier_id string) !&CarrierBinding {
	if relay_id.trim_space() == '' { return error('relay_carrier_missing_relay_id') }
	if carrier_id.trim_space() == '' {
		return error('relay_carrier_missing_carrier_id:${relay_id}')
	}
	mut owner := registry.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	binding := &CarrierBinding{ relay_id: relay_id, carrier_id: carrier_id }
	owner.bindings[relay_id] = binding
	return binding
}

pub struct CarrierDetachResult {
pub:
	relay_id   string
	carrier_id string
	trace_id   string
	removed    bool
	error      string
}

// Explicit administrative removal remains unconditional.
pub fn (mut registry CarrierRegistry) unregister(relay_id string, trace_id string) CarrierDetachResult {
	return registry.remove(relay_id, none, none, trace_id)
}

// Sessions release only their captured attachment. A stale finalizer cannot
// remove a replacement with different or reused carrier IDs, or another owner.
pub fn (mut registry CarrierRegistry) unbind(binding &CarrierBinding, trace_id string) CarrierDetachResult {
	return registry.remove(binding.relay_id, binding, none, trace_id)
}

// Serialized agent attempts retain a carrier identity rather than a hub binding.
pub fn (mut registry CarrierRegistry) unregister_carrier(relay_id string, carrier_id string, trace_id string) CarrierDetachResult {
	return registry.remove(relay_id, none, carrier_id, trace_id)
}

fn (mut registry CarrierRegistry) remove(relay_id string, expected ?&CarrierBinding, carrier ?string, trace_id string) CarrierDetachResult {
	if relay_id.trim_space() == '' {
		return CarrierDetachResult{ trace_id: trace_id, error: 'relay_carrier_missing_relay_id' }
	}
	mut owner := registry.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	current := owner.bindings[relay_id] or { return CarrierDetachResult{ relay_id: relay_id, trace_id: trace_id, error: 'relay_carrier_not_registered:${relay_id}' } }
	mut matches := true
	if binding := expected { matches = voidptr(binding) == voidptr(current) }
	if id := carrier { matches = matches && id == current.carrier_id }
	if !matches {
		return CarrierDetachResult{
			relay_id:   relay_id
			carrier_id: if binding := expected {
				binding.carrier_id
			} else {
				carrier or { '' }
			}
			trace_id:   trace_id
			error:      'relay_carrier_ownership_changed:${relay_id}'
		}
	}
	owner.bindings.delete(relay_id)
	return CarrierDetachResult{ relay_id: relay_id, carrier_id: current.carrier_id, trace_id: trace_id, removed: true }
}

fn (registry CarrierRegistry) binding(relay_id string) ?&CarrierBinding {
	mut owner := registry.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return owner.bindings[relay_id] or { none }
}

fn (registry CarrierRegistry) snapshot_ids() map[string]string {
	mut owner := registry.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	mut ids := map[string]string{}
	for relay_id, binding in owner.bindings { ids[relay_id] = binding.carrier_id }
	return ids
}

pub fn (registry CarrierRegistry) carrier_id(relay_id string) string {
	binding := registry.binding(relay_id) or { return 'disabled:${relay_id}' }
	return binding.carrier_id
}

pub fn (registry CarrierRegistry) registered(relay_id string) bool {
	return registry.binding(relay_id) != none
}

pub struct CarrierDispatchPlan {
	owner        ?&CarrierRegistryOwner
	registration ?&CarrierBinding
pub:
	relay_id   string
	carrier_id string
	available  bool
	trace_id   string
	frame_id   string
	error      string
}

pub fn carrier_dispatch_plan(registry CarrierRegistry, relay_id string, frame WireFrame) CarrierDispatchPlan {
	binding := registry.binding(relay_id)
	available := binding != none
	carrier_id := if current := binding { current.carrier_id } else { 'disabled:${relay_id}' }
	return CarrierDispatchPlan{
		owner:        registry.owner
		registration: binding
		relay_id:     relay_id
		carrier_id:   carrier_id
		available:    available
		trace_id:     frame.trace_id
		frame_id:     frame.id
		error:        if available { '' } else { 'relay_carrier_unavailable:${relay_id}' }
	}
}

// A prepared route borrows exactly one attachment. Copies of the registry
// share its owner; public IDs cannot recreate this registration capability.
// This is a send admission point, not a lock held across callbacks or I/O.
fn (plan CarrierDispatchPlan) admits_binding(relay_id string, carrier_id string) bool {
	if !plan.available || relay_id != plan.relay_id || carrier_id != plan.carrier_id {
		return false
	}
	expected := plan.registration or { return false }
	if expected.relay_id != relay_id || expected.carrier_id != carrier_id { return false }
	mut owner := plan.owner or { return false }
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	current := owner.bindings[relay_id] or { return false }
	return voidptr(current) == voidptr(expected)
}

pub fn carrier_dispatch_plan_event_fields(plan CarrierDispatchPlan) map[string]string {
	return event_fields(if plan.available {
		'carrier.dispatch'
	} else {
		'carrier.dispatch_unavailable'
	},
		plan.trace_id, {
			'relay_id':   plan.relay_id
			'carrier_id': plan.carrier_id
			'frame_id':   plan.frame_id
			'error':      plan.error
		})
}

pub fn carrier_detach_event_fields(result CarrierDetachResult) map[string]string {
	return event_fields(if result.removed { 'carrier.detach' } else { 'carrier.detach_failed' },
		result.trace_id, {
			'relay_id':   result.relay_id
			'carrier_id': result.carrier_id
			'error':      result.error
		})
}
