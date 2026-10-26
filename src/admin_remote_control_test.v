module main

import os
import time

fn test_remote_revision_covers_every_include_and_preserves_private_operation() ! {
	root := os.join_path(os.temp_dir(), 'vhttpd-remote-manifest-${time.now().unix_micro()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'vhttpd.toml')
	os.write_file(path, 'version=2\ninclude=["a.toml","b.toml"]\n')!
	os.write_file(os.join_path(root, 'a.toml'), '# first\n')!
	os.write_file(os.join_path(root, 'b.toml'), '# second\n')!
	before := remote_project_revision(path)!
	os.write_file(os.join_path(root, 'b.toml'), '# second changed\n')!
	assert remote_project_revision(path)! != before
	operation := RemoteRestartOperation{ id: 'a1'.repeat(12), state: 'queued', expected_boot: 'boot', expected_revision: before }
	remote_write_operation(path, operation)!
	assert remote_read_operation(path, operation.id)! == operation
	file := os.join_path(remote_control_dir(path)!, 'operation-${operation.id}.json')
	assert os.stat(file)!.mode & 0o077 == 0
	for id in ['', '../outside', 'g'.repeat(24)] {
		remote_read_operation(path, id) or { continue }
		assert false, 'operation path traversal accepted'
	}
}

fn test_remote_control_rejects_invalid_operation_before_any_restart() {
	remote_begin_restart(RemoteRestartRequest{ operation_id: '../not-an-operation' }) or {
		assert err.msg() == 'invalid_operation'
		return
	}
	assert false
}

fn test_sources_changed_during_startup_never_claim_loaded_manifest() ! {
	root := os.join_path(os.temp_dir(), 'vhttpd-startup-manifest-${time.now().unix_micro()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'vhttpd.toml')
	os.write_file(path, 'version=2\ninclude=["routes.toml"]\n')!
	os.write_file(os.join_path(root, 'routes.toml'), '# original\n')!
	remote_control_initialize(['--config', path], true)!
	mut state := unsafe { &g_manual_remote }
	defer {
		state.mu.@lock()
		state.root = ''
		state.effective_revision = ''
		state.manual = false
		state.mu.unlock()
	}
	assert state.effective_revision != ''
	os.write_file(os.join_path(root, 'routes.toml'), '# changed during warmup\n')!
	remote_control_note_startup()
	assert state.effective_revision == ''
}

fn test_remote_config_source_matches_env_positional_and_symlink_loading() ! {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'vhttpd-source-identity-${time.now().unix_micro()}')
	os.mkdir_all(os.join_path(root, 'target'))!
	os.mkdir_all(os.join_path(root, 'entry'))!
	defer { os.rmdir_all(root) or {} }
	target := os.join_path(root, 'target', 'vhttpd.toml')
	entry := os.join_path(root, 'entry', 'vhttpd.toml')
	os.write_file(target, 'version=2\ninclude=["routes.toml"]\n')!
	os.write_file(os.join_path(root, 'entry', 'routes.toml'), '# actual include\n')!
	os.symlink(target, entry)!
	previous := os.getenv_opt('VHTTPD_CONFIG')
	os.setenv('VHTTPD_CONFIG', entry, true)
	mut state := unsafe { &g_manual_remote }
	defer {
		if value := previous {
			os.setenv('VHTTPD_CONFIG', value, true)
		} else {
			os.unsetenv('VHTTPD_CONFIG')
		}
		state.mu.@lock()
		state.root = ''
		state.effective_revision = ''
		state.manual = false
		state.mu.unlock()
	}
	remote_control_initialize([], true)!
	assert state.root == os.abs_path(entry)
	assert state.effective_revision == remote_project_revision(entry)!
	os.unsetenv('VHTTPD_CONFIG')
	remote_control_initialize([entry], true)!
	assert state.root == os.abs_path(entry)
}

fn test_manual_restart_is_blocked_during_runtime_upgrade() ! {
 root := os.join_path(os.temp_dir(),'restart-upgrade-lock-' + time.now().unix_micro().str())
 os.mkdir(root)!
 defer { os.rmdir_all(root) or {} }
 path := os.join_path(root,'vhttpd.toml')
 os.write_file(path,'version=2\n')!
 remote_control_initialize(['--config',path],true)!
 mut state := unsafe { &g_manual_remote }
 defer { state.root=''; state.manual=false; state.effective_revision='' }
 os.mkdir(os.join_path(root,'.desktop-runtime-lock'))!
 mut rejected := false
 remote_begin_restart(RemoteRestartRequest{operation_id:'ab'.repeat(12)}) or { rejected=true; assert err.msg() == 'runtime_upgrade_in_progress' }
 assert rejected
}
