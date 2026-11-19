module configcache

import sync
import x.json2

const max_snapshot_bytes = 256 * 1024
const max_path_bytes = 1024
const max_entries = 32
const max_entry_bytes = 64 * 1024

// One owner, one configuration snapshot, bounded serialized lookup results.
// No parsed JSON tree or JS value survives a miss. The owner must close this
// cache when its runtime is retired, even if a callback still references it.
pub struct Cache {
mut:
	mu          sync.Mutex
	snapshot    string
	ready       bool
	values      map[string]string
	entry_bytes int
	closed      bool
}

pub fn resolve(raw_json string, path string) string {
	if raw_json.trim_space() == '' { return '' }
	if path.trim_space() == '' { return raw_json }
	parsed := json2.decode[json2.Any](raw_json) or { return '' }
	mut current := parsed
	for raw_part in path.split('.') {
		part := raw_part.trim_space()
		if part == '' { continue }
		root := current.as_map()
		current = root[part] or { return '' }
	}
	return current.json_str()
}

fn (mut c Cache) clear_locked() {
	c.snapshot = ''
	c.ready = false
	c.values = map[string]string{}
	c.entry_bytes = 0
}

pub fn (mut c Cache) close() {
	c.mu.@lock()
	defer { c.mu.unlock() }
	c.clear_locked()
	c.closed = true
}

pub fn (mut c Cache) is_closed() bool {
	c.mu.@lock()
	defer { c.mu.unlock() }
	return c.closed
}

pub fn (mut c Cache) entry_count() int {
	c.mu.@lock()
	defer { c.mu.unlock() }
	return c.values.len
}

pub fn (mut c Cache) lookup(raw_json string, path string) string {
	c.mu.@lock()
	if c.closed || raw_json.len > max_snapshot_bytes || path.len > max_path_bytes {
		c.clear_locked()
		c.mu.unlock()
		return resolve(raw_json, path)
	}
	defer { c.mu.unlock() }
	if !c.ready || c.snapshot != raw_json {
		c.clear_locked()
		// Own the bounded bytes, rather than retaining a slice of a larger buffer.
		c.snapshot = raw_json.clone()
		c.ready = true
	}
	// Preserve the existing raw-document contract, including invalid JSON.
	if path.trim_space() == '' { return resolve(raw_json, path) }
	if value := c.values[path] { return value }
	value := resolve(raw_json, path)
	bytes := path.len + value.len
	if c.values.len < max_entries && bytes <= max_entry_bytes - c.entry_bytes {
		c.values[path.clone()] = value.clone()
		c.entry_bytes += bytes
	}
	return value
}
