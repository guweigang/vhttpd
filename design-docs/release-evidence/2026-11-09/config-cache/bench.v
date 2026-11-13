module main

import configcache
import json2 as json
import time

#include <gc.h>
fn C.GC_get_total_bytes() u64

fn main() {
	mut fields := []string{}
	for i in 0 .. 64 {
		fields << '"setting_${i}":{"name":"${"x".repeat(150)}","enabled":true,"items":[1,2,3]}'
	}
	raw := '{"relay":{"debug":true,"ttl":3600},"settings":{' + fields.join(',') + '}}'
	paths := ['relay.debug', 'relay.ttl', 'missing', 'settings.setting_0.enabled']
	mut cache := &configcache.Cache{}
	for p in paths { cache.lookup(raw, p) }
	mut before_sum := 0
	old_start := C.GC_get_total_bytes()
	old_clock := time.sys_mono_now()
	for i in 0 .. 1000 { before_sum += configcache.resolve(raw, paths[i % paths.len]).len }
	old_ns := time.sys_mono_now() - old_clock
	old_bytes := C.GC_get_total_bytes() - old_start
	mut after_sum := 0
	new_start := C.GC_get_total_bytes()
	new_clock := time.sys_mono_now()
	for i in 0 .. 1000 { after_sum += cache.lookup(raw, paths[i % paths.len]).len }
	new_ns := time.sys_mono_now() - new_clock
	new_bytes := C.GC_get_total_bytes() - new_start
	if before_sum != after_sum || cache.entry_count() != 4 { panic('lookup parity') }
	println(json.encode(map[string]i64{
		'fixture_bytes': raw.len
		'lookups': 1000
		'uncached_gc_allocated_bytes': i64(old_bytes)
		'cached_gc_allocated_bytes': i64(new_bytes)
		'uncached_ns': old_ns
		'cached_ns': new_ns
		'checksum': before_sum
	}))
	cache.close()
	if cache.entry_count() != 0 { panic('close retention') }
}
