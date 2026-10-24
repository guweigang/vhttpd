module host

import os

fn test_bundled_runtime_is_preferred_and_development_fallback_remains_available() ! {
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
