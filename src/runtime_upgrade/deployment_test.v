module runtime_upgrade

import os
import crypto.sha256
import time

fn test_application_file_transaction_restores_old_files_and_removes_new_files() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'app-switch-' + time.now().unix_micro().str())
	project := root + '/project'
	op := root + '/operation'
	for p in [project, op + '/candidate', op + '/previous'] { os.mkdir_all(p)! }
	defer { os.rmdir_all(root) or {} }
	os.write_file(project + '/main.mjs', 'old')!
	os.chmod(project + '/main.mjs', 0o640)!
	os.write_file(op + '/previous/main.mjs', 'old')!
	os.write_file(op + '/candidate/main.mjs', 'new')!
	os.write_file(op + '/candidate/asset.bin', 'asset')!
	old := deployment_file(project, 'main.mjs')!
	files := [
		DeploymentFile{ ...old, after_hash: sha256.hexhash('new'), after_mode: 0o600 },
		DeploymentFile{ path: 'asset.bin', after_hash: sha256.hexhash('asset'), after_mode: 0o600 },
	]
	verify_deployment_inputs(project, files)!
	write_deployment_files(project, op, files, false)!
	check_deployed_files(project, files)!
	write_deployment_files(project, op, files, true)!
	assert os.read_file(project + '/main.mjs')! == 'old'
	assert os.stat(project + '/main.mjs')!.mode & 0o777 == 0o640
	assert !os.exists(project + '/asset.bin')
	os.write_file(project + '/main.mjs', 'outside edit')!
	mut stale := false
	verify_deployment_inputs(project, files) or { stale = true }
	assert stale
}

fn test_deployment_status_does_not_echo_sensitive_errors() {
	assert deployment_safe_error('token=do-not-print') == 'application_deployment_failed'
	assert DeploymentStatus{ phase: 'rolled_back' }.finished()
	assert !DeploymentStatus{ phase: 'switching' }.finished()
}
