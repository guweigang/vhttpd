module memidle

import os

// Keep the policy/concurrency checks in the normal module test discovery.
// The independent C executable owns its own clock/state and cannot modify the
// V test process's live activity gate.
fn test_idle_policy_and_concurrent_activity() {
	root := os.join_path(os.temp_dir(), 'vhttpd-idle-policy-${os.getpid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut compiler := os.getenv('V_CC')
	if compiler == '' { compiler = os.getenv('CC') }
	if compiler == '' {
		$if windows { compiler = 'gcc' } $else { compiler = 'cc' }
	}
	if compiler in ['msvc', 'cl.exe'] { compiler = 'cl' }
	binary := os.join_path(root, $if windows { 'policy.exe' } $else { 'policy' })
	source := os.join_path(@VMODROOT, 'src', 'memidle', 'idle_policy_test.c')
	mut args := []string{}
	if compiler == 'cl' {
		args = ['/nologo', '/TC', '/std:c11', source, '/Fe:${binary}', '/link', 'kernel32.lib']
	} else {
		args = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror']
		$if !windows { args << '-pthread' }
		args << [source, '-o', binary]
	}
	mut build := os.new_process(compiler)
	build.set_work_folder(root)
	build.set_args(args)
	build.set_redirect_stdio()
	build.run()
	build.wait()
	message := build.stdout_slurp()+build.stderr_slurp()
	code := build.code
	build.close()
	assert code == 0, message
	mut run := os.new_process(binary)
	run.set_redirect_stdio()
	run.run()
	run.wait()
	result := run.stdout_slurp()+run.stderr_slurp()
	exit_code := run.code
	run.close()
	assert exit_code == 0, result
}
