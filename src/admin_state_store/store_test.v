module admin_state_store

import os
import time

fn admin_state_store_test_root(name string) string {
	return os.join_path(os.temp_dir(), '${name}_${time.now().unix_micro()}')
}

fn test_file_store_put_get_list_and_delete() {
	root := admin_state_store_test_root('vhttpd_admin_state_store_roundtrip')
	defer {
		os.rmdir_all(root) or {}
	}
	mut store := FileStore.new(root) or { panic(err) }
	store.put('drafts', 'draft_1', '{"id":"draft_1"}') or { panic(err) }
	store.put('drafts', 'draft_2', '{"id":"draft_2"}') or { panic(err) }

	entry := store.get('drafts', 'draft_1') or { panic(err) }
	assert entry.namespace == 'drafts'
	assert entry.key == 'draft_1'
	assert entry.value == '{"id":"draft_1"}'

	entries := store.list('drafts') or { panic(err) }
	assert entries.len == 2
	assert entries[0].key == 'draft_1'
	assert entries[1].key == 'draft_2'

	store.delete('drafts', 'draft_1') or { panic(err) }
	if _ := store.get('drafts', 'draft_1') {
		assert false
	} else {
		assert err.msg() == 'admin_state_store_key_missing:drafts/draft_1'
	}
}

fn test_file_store_rejects_path_segments() {
	root := admin_state_store_test_root('vhttpd_admin_state_store_segments')
	defer {
		os.rmdir_all(root) or {}
	}
	mut store := FileStore.new(root) or { panic(err) }
	if _ := store.put('../drafts', 'draft_1', '{}') {
		assert false
	} else {
		assert err.msg() == 'admin_state_store_invalid_segment:../drafts'
	}
}

fn test_file_store_appends_and_lists_events() {
	root := admin_state_store_test_root('vhttpd_admin_state_store_events')
	defer {
		os.rmdir_all(root) or {}
	}
	mut store := FileStore.new(root) or { panic(err) }
	first := store.append_event('admin.draft.created', {
		'draft': 'draft_1'
	}) or {
		panic(err)
	}
	second := store.append_event('admin.draft.validated', {
		'draft':  'draft_1'
		'status': 'ok'
	}) or {
		panic(err)
	}

	events := store.list_events(0) or { panic(err) }
	assert events.len == 2
	assert events[0].id == first.id
	assert events[0].type_ == 'admin.draft.created'
	assert events[0].fields['draft'] == 'draft_1'
	assert events[1].id == second.id
	assert events[1].fields['status'] == 'ok'

	recent := store.list_events(1) or { panic(err) }
	assert recent.len == 1
	assert recent[0].id == second.id
}
