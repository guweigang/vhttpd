module relay

pub struct CarrierRegistry {
pub mut:
	ids map[string]string
}

pub fn new_carrier_registry() CarrierRegistry {
	return CarrierRegistry{
		ids: map[string]string{}
	}
}

pub fn (mut registry CarrierRegistry) register(relay_id string, carrier_id string) ! {
	if relay_id.trim_space() == '' {
		return error('relay_carrier_missing_relay_id')
	}
	if carrier_id.trim_space() == '' {
		return error('relay_carrier_missing_carrier_id:${relay_id}')
	}
	registry.ids[relay_id] = carrier_id
}

pub struct CarrierDetachResult {
pub:
	relay_id   string
	carrier_id string
	trace_id   string
	removed    bool
	error      string
}

pub fn (mut registry CarrierRegistry) unregister(relay_id string, trace_id string) CarrierDetachResult {
	if relay_id.trim_space() == '' {
		return CarrierDetachResult{
			trace_id: trace_id
			error:    'relay_carrier_missing_relay_id'
		}
	}
	carrier_id := registry.ids[relay_id] or {
		return CarrierDetachResult{
			relay_id: relay_id
			trace_id: trace_id
			error:    'relay_carrier_not_registered:${relay_id}'
		}
	}
	registry.ids.delete(relay_id)
	return CarrierDetachResult{
		relay_id:   relay_id
		carrier_id: carrier_id
		trace_id:   trace_id
		removed:    true
	}
}

pub fn (registry CarrierRegistry) carrier_id(relay_id string) string {
	return registry.ids[relay_id] or { 'disabled:${relay_id}' }
}

pub fn (registry CarrierRegistry) registered(relay_id string) bool {
	return relay_id in registry.ids
}

pub struct CarrierDispatchPlan {
pub:
	relay_id   string
	carrier_id string
	available  bool
	trace_id   string
	frame_id   string
	error      string
}

pub fn carrier_dispatch_plan(registry CarrierRegistry, relay_id string, frame WireFrame) CarrierDispatchPlan {
	carrier_id := registry.carrier_id(relay_id)
	available := registry.registered(relay_id)
	return CarrierDispatchPlan{
		relay_id:   relay_id
		carrier_id: carrier_id
		available:  available
		trace_id:   frame.trace_id
		frame_id:   frame.id
		error:      if available { '' } else { 'relay_carrier_unavailable:${relay_id}' }
	}
}

pub fn carrier_dispatch_plan_event_fields(plan CarrierDispatchPlan) map[string]string {
	return event_fields(if plan.available { 'carrier.dispatch' } else { 'carrier.dispatch_unavailable' },
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
