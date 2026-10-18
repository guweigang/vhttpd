module host

import os

pub fn workbench_data_dir() string {
	return os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR') or {
		os.join_path(os.home_dir(), 'Library', 'Application Support', 'vhttpd-workbench')
	}
}

pub fn workbench_binary(executable string, development_root string) string {
	bundled := os.join_path(os.dir(executable), '..', 'Resources', 'runtime', 'vhttpd')
	if os.is_executable(bundled) { return os.real_path(bundled) }
	return os.join_path(development_root, 'vhttpd')
}

pub fn workbench_brand_mark(executable string, development_root string) string {
	bundled := os.join_path(os.dir(executable), '..', 'Resources', 'vhttpd-mark.png')
	if os.is_file(bundled) { return os.real_path(bundled) }
	return os.join_path(development_root, 'admin', 'ui', 'brand', 'mark.png')
}
