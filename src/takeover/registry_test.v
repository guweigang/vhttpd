module takeover

import relay
import app_meta

fn test_account_selection_expiry_and_explicit_end() ! {
	mut carriers := relay.new_carrier_registry()
	carriers.register('debug', 'one')!
	binding := relay.carrier_dispatch_plan(carriers, 'debug', relay.WireFrame{})
	mut registry := Registry{}
	lease := Lease{ id: 'lease-one', app_id: 'app', accounts: ['alice'], relay_id: 'debug', route: 'debug/http', expires_ms: 5000, binding: binding }
	registry.start(lease, 1000)!
	assert registry.admit('other-app', 'alice', 1001)!.id == ''
	assert registry.admit('app', 'bob', 1001)!.id == ''
	selected := registry.admit('app', 'alice', 1001)!
	assert selected.id == 'lease-one'
	registry.finish()
	registry.stop('old-lease', 'one') or { assert err.msg() == 'takeover_owner_changed' }
	assert registry.status(1002) != none
	registry.stop('lease-one', 'one')!
	assert registry.admit('app', 'alice', 1003)!.id == ''
	registry.start(lease, 1003)!
	assert registry.admit('app', 'alice', 5000)!.id == ''
}

fn test_reconnect_never_resurrects_selection_and_old_end_cannot_stop_new_lease() ! {
	mut carriers := relay.new_carrier_registry()
	carriers.register('debug', 'same-id')!
	first := relay.carrier_dispatch_plan(carriers, 'debug', relay.WireFrame{})
	mut registry := Registry{}
	registry.start(Lease{ id: 'one', app_id: 'app', accounts: ['alice'], relay_id: 'debug', route: 'debug/http', expires_ms: 5000, binding: first }, 1000)!
	carriers.register('debug', 'same-id')!
	assert registry.admit('app', 'alice', 1001)!.id == ''
	second := relay.carrier_dispatch_plan(carriers, 'debug', relay.WireFrame{})
	registry.start(Lease{ id: 'two', app_id: 'app', accounts: ['alice'], relay_id: 'debug', route: 'debug/http', expires_ms: 5000, binding: second }, 1002)!
	registry.stop('one', 'same-id') or { assert err.msg() == 'takeover_owner_changed' }
	assert registry.status(1003)?.id == 'two'
}

fn test_admission_bounded_and_inflight_survives_end_without_replay() ! {
	mut carriers := relay.new_carrier_registry()
	carriers.register('debug', 'one')!
	mut registry := Registry{}
	registry.start(Lease{ id: 'one', app_id: 'app', accounts: ['alice'], relay_id: 'debug', route: 'debug/http', expires_ms: 5000, binding: relay.carrier_dispatch_plan(carriers, 'debug', relay.WireFrame{}) }, 1000)!
	for _ in 0 .. 8 {
		assert registry.admit('app', 'alice', 1001)!.id == 'one'
	}
	registry.admit('app', 'alice', 1001) or { assert err.msg() == 'takeover_busy' }
	registry.stop('one', 'one')!
	assert registry.admit('app', 'alice', 1001)!.id == ''
	for _ in 0 .. 8 { registry.finish() }
}

fn test_bound_takeover_requires_both_stable_application_and_installation_identity() ! {
	mut carriers := relay.new_carrier_registry()
	carriers.register('debug', 'one')!
	app_id := app_meta.new_id()!
	installation_id := app_meta.new_id()!
	mut registry := Registry{}
	registry.start(Lease{ id: 'bound', app_id: 'auth-app', accounts: ['alice'], application_id: app_id, installation_id: installation_id, local_engine_id: 'local-app', relay_id: 'debug', route: 'debug/http', expires_ms: 5000, binding: relay.carrier_dispatch_plan(carriers, 'debug', relay.WireFrame{}) }, 1000)!
	assert registry.admit('auth-app', 'alice', 1001)!.id == ''
	assert registry.admit_identity('auth-app', 'alice', app_id, app_meta.new_id()!, 1001)!.id == ''
	assert registry.admit_identity('auth-app', 'alice', app_meta.new_id()!, installation_id, 1001)!.id == ''
	assert registry.executions() == 0
	assert registry.admit_identity('auth-app', 'alice', app_id, installation_id, 1001)!.id == 'bound'
	registry.finish()
}
