module relay

fn test_carrier_registry_returns_registered_carrier_id() {
	mut registry := new_carrier_registry()
	registry.register('relay_1', 'carrier_1') or { panic(err) }

	assert registry.registered('relay_1')
	assert registry.carrier_id('relay_1') == 'carrier_1'
}

fn test_carrier_registry_returns_disabled_fallback_for_missing_relay() {
	registry := new_carrier_registry()

	assert !registry.registered('relay_1')
	assert registry.carrier_id('relay_1') == 'disabled:relay_1'
}

fn test_carrier_dispatch_plan_reports_unavailable_with_trace() {
	registry := new_carrier_registry()
	plan := carrier_dispatch_plan(registry, 'relay_1', WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_1'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	})
	fields := carrier_dispatch_plan_event_fields(plan)

	assert !plan.available
	assert plan.carrier_id == 'disabled:relay_1'
	assert plan.error == 'relay_carrier_unavailable:relay_1'
	assert fields['relay_event'] == 'carrier.dispatch_unavailable'
	assert fields['trace_id'] == 'trace_1'
	assert fields['relay_id'] == 'relay_1'
	assert fields['carrier_id'] == 'disabled:relay_1'
}

fn test_carrier_dispatch_plan_reports_available_registered_carrier() {
	mut registry := new_carrier_registry()
	registry.register('relay_1', 'carrier_1') or { panic(err) }

	plan := carrier_dispatch_plan(registry, 'relay_1', new_frame(.data, 'frm_1', 'trace_1'))

	assert plan.available
	assert plan.carrier_id == 'carrier_1'
	assert plan.error == ''
}

fn test_carrier_registry_unregister_removes_mapping_and_emits_fields() {
	mut registry := new_carrier_registry()
	registry.register('relay_1', 'carrier_1') or { panic(err) }

	result := registry.unregister('relay_1', 'trace_1')
	fields := carrier_detach_event_fields(result)

	assert result.removed
	assert result.relay_id == 'relay_1'
	assert result.carrier_id == 'carrier_1'
	assert !registry.registered('relay_1')
	assert fields['relay_event'] == 'carrier.detach'
	assert fields['trace_id'] == 'trace_1'
	assert fields['relay_id'] == 'relay_1'
	assert fields['carrier_id'] == 'carrier_1'
}

fn test_carrier_registry_unregister_missing_relay_is_deterministic() {
	mut registry := new_carrier_registry()

	result := registry.unregister('relay_1', 'trace_1')
	fields := carrier_detach_event_fields(result)

	assert !result.removed
	assert result.error == 'relay_carrier_not_registered:relay_1'
	assert fields['relay_event'] == 'carrier.detach_failed'
	assert fields['error'] == 'relay_carrier_not_registered:relay_1'
}
