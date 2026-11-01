module host

import os

fn test_bundled_runtime_is_preferred_and_development_fallback_remains_available() ! {
	$if !macos {
		return
	}
	dir := os.join_path(os.real_path(os.temp_dir()), 'workbench-bundle with spaces-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	executable := os.join_path(dir, 'Example.app', 'Contents', 'MacOS', 'workbench')
	os.mkdir_all(os.dir(executable))!
	bundled := os.join_path(dir, 'Example.app', 'Contents', 'Resources', 'runtime', 'vhttpd')
	assert workbench_binary(executable, '/development') == bundled
	assert workbench_binary('/tmp/workbench', '/development') == '/development/vhttpd'
	os.mkdir_all(os.dir(bundled))!
	os.write_file(bundled, '#!/bin/sh\nexit 0\n')!
	os.chmod(bundled, 0o755)!
	assert workbench_binary(executable, '/development') == os.real_path(bundled)
}

fn test_linux_bundle_and_xdg_data_paths() ! {
	$if linux {
		old_data := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
		old_xdg := os.getenv_opt('XDG_DATA_HOME')
		defer {
			if value := old_data {
				os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
			} else {
				os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
			}
			if value := old_xdg {
				os.setenv('XDG_DATA_HOME', value, true)
			} else {
				os.unsetenv('XDG_DATA_HOME')
			}
		}
		os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		os.setenv('XDG_DATA_HOME', 'relative-invalid', true)
		assert workbench_data_dir() == os.join_path(os.home_dir(), '.local/share/vhttpd-workbench')
		os.setenv('XDG_DATA_HOME', '/tmp/xdg-fixture', true)
		assert workbench_data_dir() == '/tmp/xdg-fixture/vhttpd-workbench'
		root := os.join_path(os.real_path(os.temp_dir()), 'workbench-linux-' + os.getpid().str())
		os.mkdir_all(root + '/resources')!
		defer { os.rmdir_all(root) or {} }
		assert workbench_binary(root + '/vhttpd-workbench', '/developer') == root + '/runtime/vhttpd'
	}
}
