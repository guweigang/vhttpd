module host

import os
import time

fn test_long_lived_default_application_does_not_block_lifecycle_worker() ! {
	$if !linux { return }
	dir := os.join_path(os.temp_dir(), 'workbench-opener-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	opener := os.join_path(dir, 'test-opener')
	result := os.join_path(dir, 'literal ; target.txt')
	os.write_file(opener, '#!/bin/sh\nsleep 2\nprintf done > "$1"\n')!
	os.chmod(opener, 0o700)!
	start := time.ticks()
	dispatch_linux_open(opener, result)!
	assert time.ticks() - start < 1000
	assert !os.exists(result)
	deadline := time.ticks() + 5000
	for !os.exists(result) && time.ticks() < deadline { time.sleep(20 * time.millisecond) }
	assert os.read_file(result)! == 'done'
	dispatch_linux_open('/bin/false', result) or { return }
	assert false, 'immediate opener failure must remain actionable'
}
