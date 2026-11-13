module app_bundle

import os
import encoding.base64
import time
import toml

fn test_bundle_preserves_cross_include_environment_and_binary_assets() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'app-bundle-' + time.now().unix_micro().str())
	local := root + '/local'
	remote := root + '/remote'
	stage := root + '/stage'
	for p in [local, remote, stage] { os.mkdir_all(p)! }
	defer { os.rmdir_all(root) or {} }
	common := 'version=2\ninclude=["cfg/app.toml"]\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=19881\n[listeners.admin]\nprotocol="http"\nport=2018\n[control]\nlistener="listener:admin"\ntoken="LOCAL-SECRET"\n'
	child := '[engines.app]\nkind="vjsx"\nentry="../main.mjs"\n[adapters.app]\nkind="http-handler"\nengine="engine:app"\n[[pipelines]]\nid="hello"\ningress="listener:web"\negress="adapter:app"\nmatch.paths=["/hello"]\n'
	for dir in [local, remote] {
		os.mkdir_all(dir + '/cfg')!
		os.write_file(dir + '/vhttpd.toml', if dir == local {
			common
		} else {
			common.replace('19881', '39101').replace('2018', '39102').replace('LOCAL-SECRET', 'REMOTE-SECRET')
		})!
		os.write_file(dir + '/cfg/app.toml', child)!
		os.write_file(dir + '/main.mjs', 'export default c => c.text("hello")')!
	}
	os.mkdir_all(local + '/public')!
	os.write_file_array(local + '/public/image.bin', [u8(0), 1, 255])!
	os.write_file(local + '/.env', 'PRIVATE')!
	payload := collect(local, local + '/vhttpd.toml', 'a'.repeat(24))!
	assert !payload.files.any(it.path == '.env')
	assert !payload.files.any(base64.decode_str(it.data).contains('LOCAL-SECRET'))
	materialize(payload, stage)!
	preserve_remote(stage, payload, remote + '/vhttpd.toml')!
	doc := toml.parse_file(stage + '/vhttpd.toml')!
	assert doc.value('listeners.web.port').int() == 39101
	assert doc.value('control.token').string() == 'REMOTE-SECRET'
	assert os.read_bytes(stage + '/public/image.bin')! == [u8(0), 1, 255]
	assert toml.parse_file(stage + '/cfg/app.toml')!.value('engines.app.entry').string() == '../main.mjs'
	// Target environment must exist: local credentials never become a fallback.
	os.write_file(remote + '/vhttpd.toml', common.replace('token="LOCAL-SECRET"', ''))!
	mut credential_rejected := false
	preserve_remote(stage, payload, remote + '/vhttpd.toml') or { credential_rejected = err.msg() == 'remote_credential_required' }
	assert credential_rejected
	os.write_file(remote + '/vhttpd.toml', common.replace('listeners.web', 'listeners.other'))!
	mut mapping_rejected := false
	preserve_remote(stage, payload, remote + '/vhttpd.toml') or { mapping_rejected = err.msg() == 'listener_mapping_required' }
	assert mapping_rejected
	// A changed file cannot bypass checksum validation.
	mut bad_files := payload.files.clone()
	bad_files[0] = File{ ...bad_files[0], data: base64.encode_str('changed') }
	mut checksum_rejected := false
	Payload{ ...payload, files: bad_files }.validate() or { checksum_rejected = err.msg() == 'bundle_checksum_mismatch' }
	assert checksum_rejected
	os.symlink(local + '/main.mjs', local + '/linked.mjs')!
	mut link_rejected := false
	collect(local, local + '/vhttpd.toml', 'b'.repeat(24)) or { link_rejected = err.msg() == 'project_symlink_not_supported' }
	assert link_rejected
	assert !safe_path('../outside') && !safe_path('x/../y') && !safe_path('.desktop-runtime-id')
}
