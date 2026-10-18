module cachex

import time

fn test_direct_cache_set_rejects_overflow_without_changing_value_or_success_count() {
	mut rt := Runtime.new(true, '')
	assert rt.set_value('ns', 'key', 'keep', 0)
	assert !rt.set_value('ns', 'key', 'rejected', i64(9223372036855))
	assert rt.get_value('ns', 'key') or { '' } == 'keep'
	assert rt.total_ops == 1
	assert rt.failed_ops == 1
	assert rt.last_error == 'state_store_ttl_out_of_range'
}

fn test_cache_set_and_cas_reject_overflow_before_mutation() {
	mut rt := Runtime.new(true, '')
	for op in ['set', 'patch'] {
		for ttl in [i64(9223372036855), i64(9223372036854775807)] {
			assert rt.set_value('ns', 'key', 'keep', 0)
			result := rt.dispatch(Request{ op: op, namespace: 'ns', key: 'key', value: 'rejected', expected_found: true, expected_value: 'keep', ttl_ms: ttl })
			assert !result.ok
			assert result.error == 'state_store_ttl_out_of_range'
			assert rt.get_value('ns', 'key') or { '' } == 'keep'
		}
	}
}

fn test_cache_accepts_maximum_representable_ttl() {
	mut rt := Runtime.new(true, '')
	assert rt.set_value('ns', 'key', 'long', i64(9223372036854))
	assert rt.get_value('ns', 'key') or { '' } == 'long'
}

fn test_cache_cas_negative_ttl_stays_nonexpiring_and_delete_ignores_ttl() {
	mut rt := Runtime.new(true, '')
	assert rt.set_value('ns', 'key', 'before', 0)
	result := rt.dispatch(Request{ op: 'patch', namespace: 'ns', key: 'key', value: 'after', expected_found: true, expected_value: 'before', ttl_ms: i64(-9223372036854775807) })
	assert result.ok
	time.sleep(10 * time.millisecond)
	assert rt.get_value('ns', 'key') or { '' } == 'after'
	deleted := rt.dispatch(Request{ op: 'patch', namespace: 'ns', key: 'key', expected_found: true, expected_value: 'after', delete_value: true, ttl_ms: i64(9223372036854775807) })
	assert deleted.ok
	assert rt.get_value('ns', 'key') == none
}

fn test_cache_positive_set_and_cas_ttls_still_expire() {
	mut rt := Runtime.new(true, '')
	for op in ['set', 'patch'] {
		assert rt.set_value('ns', 'key', 'before', 0)
		result := rt.dispatch(Request{ op: op, namespace: 'ns', key: 'key', value: 'short', expected_found: true, expected_value: 'before', ttl_ms: 20 })
		assert result.ok
		time.sleep(35 * time.millisecond)
		assert rt.get_value('ns', 'key') == none
	}
}
