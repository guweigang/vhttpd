module runtime_upgrade

import os
import time

fn test_runtime_upgrade_revision_observes_every_include() ! {
	dir := os.join_path(os.temp_dir(), 'upgrade-plan-' + time.ticks().str())
	os.mkdir(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := os.join_path(dir, 'vhttpd.toml')
	os.write_file(root, 'version=2\ninclude=["app.toml"]\n')!
	os.write_file(os.join_path(dir, 'app.toml'), '[listeners.admin]\nprotocol="http"\nport=2018\n')!
	a := revision(root)!
	os.write_file(os.join_path(dir, 'app.toml'), '[listeners.admin]\nprotocol="http"\nport=2019\n')!
	assert revision(root)! != a
	assert !runtime_id('../bad') && !valid_id('bad')
}

fn test_upgrade_diagnostics_do_not_echo_unexpected_errors() {
	assert safe_error('token=private-example') == 'upgrade_operation_failed'
	assert safe_error('new_process_exited') == 'new_process_exited'
	assert Status{ phase: 'rolled_back' }.finished()
	assert !Status{ phase: 'starting' }.finished()
}

fn test_linux_launch_waits_for_exec_and_rejects_wrong_process_identity() ! {
	$if !linux {
		return
	}
	executable := os.real_path('/bin/sleep')
	child := launch(executable, Identity{ args: ['10'], cwd: os.temp_dir(), environment: os.environ() })!
	assert child.alive()
	mut refused := false
	signal_checked(Identity{ ...child, start: 'wrong-start-time' }) or { refused = true }
	assert refused && child.alive()
	stop(child)!
	assert !child.alive()
}

fn test_private_upgrade_writes_preserve_other_writer_and_replace_atomically() ! {
	dir := os.join_path(os.temp_dir(), 'upgrade-private-' + time.now().unix_micro().str())
	os.mkdir(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'status.json')
	private_write(path, 'before')!
	private_write(path, 'after')!
	assert os.read_file(path)! == 'after'
	assert os.stat(path)!.mode & 0o077 == 0
	os.write_file(path + '.tmp', 'another writer')!
	mut rejected := false
	private_write(path, 'unexpected') or { rejected = true }
	assert rejected && os.read_file(path)! == 'after'
	assert os.read_file(path + '.tmp')! == 'another writer'
}
