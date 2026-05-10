module main

import json
import sync
import time
import x.json2

pub interface StateStore[T] {
mut:
	get(key string) !T
	set(key string, val T) !
	set_with_ttl(key string, val T, ttl time.Duration) !
	delete(key string) !
	exists(key string) bool
	keys() []string
	list() []T
	patch(key string, updater fn (mut T) !) !
	prune_expired() int
	clear()
}

struct StoredValue {
mut:
	value         json2.Any
	created_at_ms i64
	updated_at_ms i64
	expires_at_ms i64
}

pub struct MemoryStateStore[T] {
mut:
	mu   sync.Mutex
	data map[string]StoredValue
}

pub fn new_memory_state_store[T]() MemoryStateStore[T] {
	return MemoryStateStore[T]{
		data: map[string]StoredValue{}
	}
}

fn state_store_now_ms() i64 {
	return time.now().unix_milli()
}

fn state_store_expires_at_ms(ttl time.Duration) i64 {
	if ttl <= time.Duration(0) {
		return i64(0)
	}
	return state_store_now_ms() + ttl.milliseconds()
}

fn state_store_is_expired(record StoredValue, now_ms i64) bool {
	return record.expires_at_ms > 0 && record.expires_at_ms <= now_ms
}

fn state_store_encode_value[T](val T) !json2.Any {
	$if T is string {
		return json2.Any(val)
	} $else $if T is $struct {
		return json2.Any(json2.map_from[T](val))
	} $else {
		return json2.decode[json2.Any](json.encode(val))!
	}
}

fn state_store_decode_value[T](val json2.Any) !T {
	return json2.decode[T](val.json_str())!
}

pub fn (mut store MemoryStateStore[T]) get(key string) !T {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	if record := store.data[key] {
		now_ms := state_store_now_ms()
		if state_store_is_expired(record, now_ms) {
			store.data.delete(key)
			return error('state_store_key_expired:${key}')
		}
		return state_store_decode_value[T](record.value)!
	}
	return error('state_store_key_missing:${key}')
}

pub fn (mut store MemoryStateStore[T]) set(key string, val T) ! {
	store.set_with_ttl(key, val, time.Duration(0))!
}

pub fn (mut store MemoryStateStore[T]) set_with_ttl(key string, val T, ttl time.Duration) ! {
	now_ms := state_store_now_ms()
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	if existing := store.data[key] {
		store.data[key] = StoredValue{
			value:         state_store_encode_value[T](val)!
			created_at_ms: existing.created_at_ms
			updated_at_ms: now_ms
			expires_at_ms: state_store_expires_at_ms(ttl)
		}
	} else {
		store.data[key] = StoredValue{
			value:         state_store_encode_value[T](val)!
			created_at_ms: now_ms
			updated_at_ms: now_ms
			expires_at_ms: state_store_expires_at_ms(ttl)
		}
	}
}

pub fn (mut store MemoryStateStore[T]) delete(key string) ! {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	store.data.delete(key)
}

pub fn (mut store MemoryStateStore[T]) exists(key string) bool {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	if record := store.data[key] {
		now_ms := state_store_now_ms()
		if state_store_is_expired(record, now_ms) {
			store.data.delete(key)
			return false
		}
		return true
	}
	return false
}

pub fn (mut store MemoryStateStore[T]) keys() []string {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	now_ms := state_store_now_ms()
	mut keys := []string{}
	mut expired := []string{}
	for key, record in store.data {
		if state_store_is_expired(record, now_ms) {
			expired << key
			continue
		}
		keys << key
	}
	for key in expired {
		store.data.delete(key)
	}
	keys.sort()
	return keys
}

pub fn (mut store MemoryStateStore[T]) list() []T {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	now_ms := state_store_now_ms()
	mut values := []T{}
	mut expired := []string{}
	for key, record in store.data {
		if state_store_is_expired(record, now_ms) {
			expired << key
			continue
		}
		values << state_store_decode_value[T](record.value) or { continue }
	}
	for key in expired {
		store.data.delete(key)
	}
	return values
}

pub fn (mut store MemoryStateStore[T]) patch(key string, updater fn (mut T) !) ! {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	if mut record := store.data[key] {
		now_ms := state_store_now_ms()
		if state_store_is_expired(record, now_ms) {
			store.data.delete(key)
			return error('state_store_key_expired:${key}')
		}
		mut value := state_store_decode_value[T](record.value)!
		updater(mut value)!
		record.value = state_store_encode_value[T](value)!
		record.updated_at_ms = now_ms
		store.data[key] = record
		return
	}
	return error('state_store_key_missing:${key}')
}

pub fn (mut store MemoryStateStore[T]) prune_expired() int {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	now_ms := state_store_now_ms()
	mut expired := []string{}
	for key, record in store.data {
		if state_store_is_expired(record, now_ms) {
			expired << key
		}
	}
	for key in expired {
		store.data.delete(key)
	}
	return expired.len
}

pub fn (mut store MemoryStateStore[T]) clear() {
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	store.data.clear()
}

pub fn (mut store MemoryStateStore[string]) compare_and_swap_set_with_ttl(key string, expected_found bool, expected_value string, next_value string, ttl time.Duration) !bool {
	now_ms := state_store_now_ms()
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	if mut existing := store.data[key] {
		if state_store_is_expired(existing, now_ms) {
			store.data.delete(key)
			if expected_found {
				return false
			}
		} else {
			if !expected_found {
				return false
			}
			if state_store_decode_value[string](existing.value)! != expected_value {
				return false
			}
			store.data[key] = StoredValue{
				value:         state_store_encode_value[string](next_value)!
				created_at_ms: existing.created_at_ms
				updated_at_ms: now_ms
				expires_at_ms: state_store_expires_at_ms(ttl)
			}
			return true
		}
	}
	if expected_found {
		return false
	}
	store.data[key] = StoredValue{
		value:         state_store_encode_value[string](next_value)!
		created_at_ms: now_ms
		updated_at_ms: now_ms
		expires_at_ms: state_store_expires_at_ms(ttl)
	}
	return true
}

pub fn (mut store MemoryStateStore[string]) compare_and_swap_delete(key string, expected_found bool, expected_value string) !bool {
	now_ms := state_store_now_ms()
	store.mu.@lock()
	defer {
		store.mu.unlock()
	}
	if existing := store.data[key] {
		if state_store_is_expired(existing, now_ms) {
			store.data.delete(key)
			return !expected_found
		}
		if !expected_found {
			return false
		}
		if state_store_decode_value[string](existing.value)! != expected_value {
			return false
		}
		store.data.delete(key)
		return true
	}
	return !expected_found
}
