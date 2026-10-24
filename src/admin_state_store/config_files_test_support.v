module admin_state_store

import os
import rand

fn changeset_test_files() (string, []ConfigFileChange) {
	root := os.join_path(os.temp_dir(), 'vhttpd-config-set-' + rand.hex(8))
	os.mkdir_all(root) or { panic(err) }
	a := os.join_path(root, 'a.toml')
	b := os.join_path(root, 'b.toml')
	os.write_file(a, 'old-a') or { panic(err) }
	os.write_file(b, 'old-b') or { panic(err) }
	os.chmod(a, 0o600) or { panic(err) }
	return root, [ConfigFileChange{ path: a, original: 'old-a', value: 'new-a' },
		ConfigFileChange{ path: b, original: 'old-b', value: 'new-b' }]
}

fn config_check_ok() ! {}
