module host

import os
import toml

fn test_shared_library_permissions_copy_and_corrupt_store_protection() ! {
	old := os.getenv('VHTTPD_DESKTOP_DATA_DIR')
	dir := os.join_path(os.real_path(os.temp_dir()), 'shared-relays-${os.getpid()}')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', dir, true)
	defer {
		os.setenv('VHTTPD_DESKTOP_DATA_DIR', old, true)
		os.rmdir_all(dir) or {}
	}
	r := SharedRelay{ relay_id: 'hub', id: new_shared_relay_id()!, name: '开发 Hub', url: 'ws://127.0.0.1:23456/vhttpd/relay', token: 'private-"token\nvalue' }
	save_shared_relays([r])!
	assert load_shared_relays()! == [r]
	path := os.join_path(dir, 'shared-relays.json')
	assert os.stat(path)!.mode & 0o777 == 0o600
	copy_one := shared_relay_toml(r, 'hub', 'node-a')!
	copy_two := shared_relay_toml(r, 'hub', 'node-b')!
	assert toml.parse_text(copy_one)!.value('relays.hub.token').string() == r.token
	assert copy_one.contains('autostart = false') && !copy_one.contains('node-b')
	save_shared_relays([])!
	assert copy_two.contains('node-b') // independent project copy survives library deletion
	os.write_file(path, 'invalid private contents')!
	save_shared_relays([r]) or {
		assert os.read_file(path)! == 'invalid private contents'
		return
	}
	assert false, 'Corrupt existing store was overwritten'
}

fn test_shared_connection_rejects_credential_urls_and_environment_expressions() ! {
	r := SharedRelay{ relay_id: 'hub', id: new_shared_relay_id()!, name: 'test', url: 'wss://example.com/vhttpd/relay' }
	r.validate()!
	for url in ['https://example.com', 'ws://secret@example.com/x', 'wss://example.com/x?token=secret',
		'wss://example.com/#secret'] {
		SharedRelay{ ...r, url: url }.validate() or { continue }
		assert false, 'Unsafe URL was accepted'
	}
}
