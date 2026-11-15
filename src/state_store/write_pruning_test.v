module state_store

import time

fn test_writes_release_expired_unread_values() {
	mut store := MemoryStateStore.new[string]()
	store.set_with_ttl('abandoned', 'payload', time.nanosecond) or { panic(err) }
	store.next_prune_ms = 0
	store.set('live', 'value') or { panic(err) }
	assert 'abandoned' !in store.data
	assert store.get('live') or { panic(err) } == 'value'
}

fn test_cas_prunes_without_changing_conflict_semantics() {
	mut store := MemoryStateStore.new[string]()
	store.set_with_ttl('abandoned', 'payload', time.nanosecond) or { panic(err) }
	store.next_prune_ms = 0
	assert !store.compare_and_swap_set_with_ttl('missing', true, 'old', 'new', time.second) or { panic(err) }
	assert 'abandoned' !in store.data
	assert 'missing' !in store.data
}
