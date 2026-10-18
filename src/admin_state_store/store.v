module admin_state_store

import os
import json2 as json
import time

pub struct Entry {
pub:
	namespace       string
	key             string
	value           string
	updated_at_unix i64 @[json: 'updated_at_unix']
}

pub struct Event {
pub:
	id      string
	type_   string @[json: 'type']
	at_unix i64    @[json: 'at_unix']
	fields  map[string]string
}

pub struct FileStore {
pub:
	root string
}

pub fn FileStore.new(root string) !FileStore {
	clean := root.trim_space()
	if clean == '' {
		return error('admin_state_store_missing_root')
	}
	ensure_state_directory(clean)!
	return FileStore{
		root: clean
	}
}

// First-load requests create parents independently. Accept a directory another
// request just created at each level, while preserving real file/permission errors.
fn ensure_state_directory(path string) ! {
	if os.is_dir(path) { return }
	parent := os.dir(path)
	if parent != path && parent != '' { ensure_state_directory(parent)! }
	os.mkdir(path) or {
		if !os.is_dir(path) { return err }
	}
}

pub fn (mut store FileStore) get(namespace string, key string) !Entry {
	lease := lock_directory(store.root, false)!
	defer { lease.release() }
	ns := sanitize_segment(namespace)!
	k := sanitize_segment(key)!
	path := store.entry_path(ns, k)
	value := os.read_file(path) or {
		return error('admin_state_store_key_missing:${ns}/${k}')
	}
	return Entry{
		namespace:       ns
		key:             k
		value:           value
		updated_at_unix: os.file_last_mod_unix(path)
	}
}

pub fn (mut store FileStore) put(namespace string, key string, value string) !Entry {
	ns := sanitize_segment(namespace)!
	k := sanitize_segment(key)!
	lease := lock_directory(store.root, true)!
	defer { lease.release() }
	path := store.entry_path(ns, k)
	atomic_write(path, value)!
	return Entry{
		namespace:       ns
		key:             k
		value:           value
		updated_at_unix: time.now().unix()
	}
}

pub fn (mut store FileStore) delete(namespace string, key string) ! {
	ns := sanitize_segment(namespace)!
	k := sanitize_segment(key)!
	lease := lock_directory(store.root, true)!
	defer { lease.release() }
	path := store.entry_path(ns, k)
	if os.exists(path) {
		os.rm(path)!
	}
}

pub fn (mut store FileStore) list(namespace string) ![]Entry {
	lease := lock_directory(store.root, false)!
	defer { lease.release() }
	ns := sanitize_segment(namespace)!
	dir := store.namespace_dir(ns)
	if !os.exists(dir) {
		return []Entry{}
	}
	mut entries := []Entry{}
	for name in os.ls(dir)! {
		if !name.ends_with('.json') {
			continue
		}
		key := name[..name.len - 5]
		path := os.join_path(dir, name)
		entries << Entry{
			namespace:       ns
			key:             key
			value:           os.read_file(path)!
			updated_at_unix: os.file_last_mod_unix(path)
		}
	}
	entries.sort(a.key < b.key)
	return entries
}

pub fn (mut store FileStore) append_event(type_ string, fields map[string]string) !Event {
	clean_type := type_.trim_space()
	if clean_type == '' {
		return error('admin_state_store_event_type_missing')
	}
	lease := lock_directory(store.root, true)!
	defer { lease.release() }
	event := Event{
		id:      'evt_${time.now().unix_micro()}'
		type_:   clean_type
		at_unix: time.now().unix()
		fields:  fields.clone()
	}
	append_line(store.events_path(), json.encode(event, escape_unicode: true, time_as_unix: true))!
	return event
}

pub fn (mut store FileStore) list_events(limit int) ![]Event {
	lease := lock_directory(store.root, false)!
	defer { lease.release() }
	path := store.events_path()
	if !os.exists(path) {
		return []Event{}
	}
	lines := os.read_lines(path)!
	mut events := []Event{}
	for line in lines {
		clean := line.trim_space()
		if clean == '' {
			continue
		}
		events << json.decode[Event](clean)!
	}
	if limit <= 0 || events.len <= limit {
		return events
	}
	return events[events.len - limit..]
}

fn (store FileStore) namespace_dir(namespace string) string {
	return os.join_path(store.root, namespace)
}

fn (store FileStore) entry_path(namespace string, key string) string {
	return os.join_path(store.namespace_dir(namespace), '${key}.json')
}

fn (store FileStore) events_path() string {
	return os.join_path(store.root, 'events.jsonl')
}

fn sanitize_segment(raw string) !string {
	clean := raw.trim_space()
	if clean == '' {
		return error('admin_state_store_segment_missing')
	}
	mut out := []u8{cap: clean.len}
	for ch in clean.bytes() {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`) || (ch >= `0` && ch <= `9`) {
			out << ch
			continue
		}
		if ch in [`-`, `_`, `.`] {
			out << ch
			continue
		}
		return error('admin_state_store_invalid_segment:${clean}')
	}
	return out.bytestr()
}
