module main

import time

fn test_memory_state_store_set_get_and_keys() {
	mut store := new_memory_state_store[string]()
	store.set('alpha', 'a') or { panic(err) }
	store.set('beta', 'b') or { panic(err) }

	assert store.get('alpha') or { '' } == 'a'
	assert store.get('beta') or { '' } == 'b'
	assert store.exists('alpha')
	assert store.keys() == ['alpha', 'beta']
	assert store.list().len == 2
}

fn test_memory_state_store_ttl_expiry_and_prune() {
	mut store := new_memory_state_store[string]()
	store.set_with_ttl('short', 'x', 20 * time.millisecond) or { panic(err) }
	assert store.exists('short')

	time.sleep(35 * time.millisecond)

	assert !store.exists('short')
	assert store.get('short') or { err.msg() } == 'state_store_key_missing:short'

	store.set_with_ttl('expired1', 'a', 1 * time.millisecond) or { panic(err) }
	store.set_with_ttl('expired2', 'b', 1 * time.millisecond) or { panic(err) }
	time.sleep(5 * time.millisecond)
	assert store.prune_expired() == 2
	assert store.keys().len == 0
}

fn test_memory_state_store_patch_updates_existing_value() {
	mut store := new_memory_state_store[map[string]string]()
	store.set('bag', {
		'user':  'alice'
		'count': '1'
	}) or { panic(err) }

	store.patch('bag', fn (mut val map[string]string) ! {
		val['count'] = '2'
		val['role'] = 'admin'
	}) or { panic(err) }

	bag := store.get('bag') or { panic(err) }
	assert bag['user'] == 'alice'
	assert bag['count'] == '2'
	assert bag['role'] == 'admin'
}

fn test_memory_state_store_patch_missing_key_returns_error() {
	mut store := new_memory_state_store[map[string]string]()
	store.patch('missing', fn (mut val map[string]string) ! {
		val['x'] = 'y'
	}) or {
		assert err.msg() == 'state_store_key_missing:missing'
		return
	}
	assert false
}
