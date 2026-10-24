module main

import host
import os

fn run_runtime_smoke(root string) ! {
	job := host.RuntimeJob{}
	dir := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-runtime-acceptance-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	old_data := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	old_binary := os.getenv_opt('VHTTPD_DESKTOP_BINARY')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', dir, true)
	defer {
		if value := old_data {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		if value := old_binary {
			os.setenv('VHTTPD_DESKTOP_BINARY', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_BINARY')
		}
	}
	mut archive := os.getenv('VHTTPD_RUNTIME_TEST_ARCHIVE')
	if archive == '' {
		app := os.real_path(os.join_path(os.dir(os.executable()), '..', '..'))
		archive = os.join_path(dir, 'official-layout.zip')
		mut zip := os.new_process('/usr/bin/ditto')
		zip.set_args(['-c', '-k', '--keepParent', app, archive])
		zip.run()
		zip.wait()
		if zip.code != 0 { return error('无法创建离线运行包夹具。') }
	}
	mut hash := os.new_process('/usr/bin/shasum')
	hash.set_args(['-a', '256', archive])
	hash.set_redirect_stdio_merged()
	hash.run()
	hash.wait()
	if hash.code != 0 { return error('无法计算离线运行包校验值。') }
	checksum := hash.stdout_read().fields()[0]
	installed := host.install_runtime_archive(archive, checksum, job)!
	info := host.inspect_runtime(installed, os.executable(), job)
	if !info.ready || info.source != '已下载' {
		return error('下载后运行包版本无法识别。')
	}
	os.unsetenv('VHTTPD_DESKTOP_BINARY')
	if host.selected_runtime(os.executable(), root)! != installed {
		return error('运行包选择未持久化。')
	}
	host.install_runtime_archive(archive, '0'.repeat(64), job) or {
		if host.selected_runtime(os.executable(), root)! != installed {
			return error('校验失败覆盖了当前运行包。')
		}
		os.setenv('VHTTPD_DESKTOP_BINARY', installed, true)
		run_smoke(root)!
		println('PASS runtime download/install: SHA256 → safe extraction → portable libraries/signatures → actual version → persisted selection; corrupt package preserves selection; installed runtime creates and runs both vjsx templates without development tools')
		return
	}
	return error('错误的 SHA256 被接受。')
}
