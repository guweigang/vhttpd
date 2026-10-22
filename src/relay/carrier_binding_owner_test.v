module relay

fn test_binding_identity_survives_replacement_with_reused_ids() {
	mut registry := new_carrier_registry()
	old := registry.bind('edge', 'carrier') or { panic(err) }
	current := registry.bind('edge', 'carrier') or { panic(err) }
	stale := registry.unbind(old, 'old-trace')
	assert !stale.removed
	assert stale.error == 'relay_carrier_ownership_changed:edge'
	assert registry.registered('edge')
	assert registry.unbind(current, 'new-trace').removed
	assert !registry.unbind(current, 'again').removed
}

fn test_binding_from_another_registry_cannot_remove_current_owner() {
	mut original := new_carrier_registry()
	mut replacement := new_carrier_registry()
	old := original.bind('edge', 'carrier') or { panic(err) }
	replacement.bind('edge', 'carrier') or { panic(err) }
	assert !replacement.unbind(old, 'trace').removed
	assert replacement.registered('edge')
	assert original.unbind(old, 'trace').removed
}

fn test_registry_value_copies_share_one_binding_owner() {
	mut original := new_carrier_registry()
	mut alias := original
	binding := alias.bind('edge', 'carrier') or { panic(err) }
	assert original.carrier_id('edge') == 'carrier'
	assert original.unbind(binding, 'trace').removed
	assert !alias.registered('edge')
}

fn test_registry_snapshot_has_independent_containers() {
	mut registry := new_carrier_registry()
	registry.register('edge', 'carrier') or { panic(err) }
	mut snapshot := registry.snapshot_ids()
	snapshot['edge'] = 'changed'
	snapshot['other'] = 'foreign'
	assert registry.carrier_id('edge') == 'carrier'
	assert !registry.registered('other')
}

fn test_serialized_carrier_cleanup_checks_expected_identity() {
	mut registry := new_carrier_registry()
	registry.register('edge', 'new') or { panic(err) }
	assert !registry.unregister_carrier('edge', 'old', 'trace').removed
	assert registry.carrier_id('edge') == 'new'
	assert registry.unregister_carrier('edge', 'new', 'trace').removed
}

fn churn_carrier_bindings(registry CarrierRegistry, done chan bool) {
	mut retained := registry
	for i in 0 .. 1000 {
		retained.register('edge', 'carrier-${i}') or {
			done <- false
			return
		}
		retained.unregister('edge', 'trace')
	}
	done <- true
}

fn test_dispatch_and_snapshot_are_coherent_during_carrier_replacement() {
	mut registry := new_carrier_registry()
	done := chan bool{cap: 1}
	spawn churn_carrier_bindings(registry, done)
	for _ in 0 .. 1000 {
		plan := carrier_dispatch_plan(registry, 'edge', new_frame(.data, 'frame', 'trace'))
		if plan.available {
			assert plan.carrier_id.starts_with('carrier-')
			assert plan.error == ''
		} else {
			assert plan.carrier_id == 'disabled:edge'
			assert plan.error == 'relay_carrier_unavailable:edge'
		}
		snapshot := build_carrier_snapshots(registry)
		assert snapshot.len <= 1
		if snapshot.len == 1 {
			assert snapshot[0].carrier_id.starts_with('carrier-')
		}
	}
	assert <-done
}
