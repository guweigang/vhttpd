module configcache

fn test_lookup_values_and_paths_preserve_serialized_contract() {
	mut c := Cache{}
	raw := '{"relay":{"debug":false,"ttl":0,"empty":"","nil":null,"list":[1,"x"]},"escaped":"a\\nb"}'
	for path in ['relay.debug', 'relay.ttl', 'relay.empty', 'relay.nil', 'relay.list',
		' relay .. debug ', 'missing', 'relay.missing', 'relay.ttl.child', '.', '', '  ', 'escaped'] {
		assert c.lookup(raw, path) == resolve(raw, path), path
		assert c.lookup(raw, path) == resolve(raw, path), path
	}
	assert c.lookup(raw, 'relay.debug') == 'false'
	assert c.lookup(raw, 'relay.ttl') == '0'
	assert c.lookup(raw, 'relay.empty') == '""'
	assert c.lookup(raw, 'relay.nil') == 'null'
}

fn test_snapshot_changes_invalidate_positive_and_negative_entries() {
	mut c := Cache{}
	for _ in 0 .. 4 {
		assert c.lookup('{"value":1}', 'value') == '1'
		assert c.lookup('{"value":1}', 'new') == ''
		assert c.lookup('{"value":2,"new":true}', 'value') == '2'
		assert c.lookup('{"value":2,"new":true}', 'new') == 'true'
		assert c.lookup('{"new":false}', 'value') == ''
		assert c.lookup('{"new":false}', 'new') == 'false'
	}
}

fn test_invalid_empty_and_non_object_snapshots_do_not_serve_old_values() {
	mut c := Cache{}
	for raw in ['{', '', ' \n\t', '[]', 'null', '42'] {
		assert c.lookup('{"value":1}', 'value') == '1'
		assert c.lookup(raw, 'value') == resolve(raw, 'value')
		assert c.lookup(raw, 'value') == resolve(raw, 'value')
		assert c.lookup(raw, '') == resolve(raw, '')
	}
}

fn test_unique_paths_and_large_values_have_bounded_retention() {
	mut c := Cache{}
	for i in 0 .. 1000 { assert c.lookup('{}', 'missing_${i}') == '' }
	assert c.values.len == max_entries
	assert c.entry_bytes <= max_entry_bytes
	large := '{"value":"' + 'x'.repeat(max_entry_bytes) + '"}'
	assert c.lookup(large, 'value') == resolve(large, 'value')
	assert c.values.len == 0
	assert c.entry_bytes == 0
	assert c.lookup('{"value":7}', 'value') == '7'
	oversized := '{"value":8,"padding":"' + 'x'.repeat(max_snapshot_bytes) + '"}'
	assert c.lookup(oversized, 'value') == '8'
	assert c.snapshot == '' && c.values.len == 0
	assert c.lookup('{"value":7}', 'x'.repeat(max_path_bytes + 1)) == ''
	assert c.snapshot == '' && c.values.len == 0
}

fn test_close_releases_snapshot_and_entries_even_if_callback_keeps_cache() {
	mut c := Cache{}
	assert c.lookup('{"value":1}', 'value') == '1'
	c.close()
	c.close()
	assert c.snapshot == '' && c.values.len == 0 && c.entry_bytes == 0
	assert c.lookup('{"value":2}', 'value') == '2'
	assert c.snapshot == '' && c.values.len == 0 && c.entry_bytes == 0
}

fn test_returned_values_remain_valid_after_invalidation_and_close() {
	mut c := Cache{}
	assert c.lookup('{"value":"first"}', 'value') == '"first"'
	borrowed := c.lookup('{"value":"first"}', 'value')
	assert c.lookup('{"value":"second"}', 'value') == '"second"'
	c.close()
	assert borrowed == '"first"'
}

fn cache_reader(mut c Cache, version int) {
	raw := '{"value":${version}}'
	for _ in 0 .. 100 {
		if c.lookup(raw, 'value') != version.str() { panic('cross-snapshot cache value') }
	}
}

fn test_concurrent_snapshot_changes_keep_results_associated_with_input() {
	mut c := &Cache{}
	mut jobs := []thread{}
	for i in 0 .. 4 { jobs << spawn cache_reader(mut c, i) }
	jobs.wait()
	assert c.values.len <= max_entries && c.entry_bytes <= max_entry_bytes
}
