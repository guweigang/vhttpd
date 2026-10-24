module executor

import os
import time

fn directory_identity_root(label string) string {
	return os.join_path(os.temp_dir(), 'vhttpd-directory-identity-${label}-${os.getpid()}-${time.sys_mono_now()}')
}

