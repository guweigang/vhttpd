module host

import os

pub fn workbench_data_dir() string {
	return os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR') or {
		default_workbench_data_dir()
	}
}

pub fn workbench_binary(executable string, development_root string) string {
	bundled := bundled_workbench_binary(executable)
	if os.is_executable(bundled) { return os.real_path(bundled) }
	// A broken installed app must not fall back to a developer checkout.
	if executable.contains('.app/Contents/MacOS/') { return bundled }
	$if linux || windows {
		if os.is_dir(workbench_resources(executable)) { return bundled }
	}
	return os.join_path(development_root, 'vhttpd')
}

pub fn workbench_brand_mark(executable string, development_root string) string {
	bundled := os.join_path(workbench_resources(executable), $if windows { 'vhttpd-mark.bmp' } $else { 'vhttpd-mark.png' })
	if os.is_file(bundled) { return os.real_path(bundled) }
	return os.join_path(development_root, 'admin', 'ui', 'brand', 'mark.png')
}

fn default_workbench_data_dir() string {
	$if macos {
		return os.join_path(os.home_dir(), 'Library', 'Application Support', 'vhttpd-workbench')
	} $else $if windows {
		return os.join_path(os.getenv_opt('LOCALAPPDATA') or { os.home_dir() }, 'vhttpd-workbench')
	} $else {
		base := os.getenv('XDG_DATA_HOME')
		return os.join_path(if os.is_abs_path(base) {
			base
		} else {
			os.join_path(os.home_dir(), '.local', 'share')
		}, 'vhttpd-workbench')
	}
}

fn workbench_resources(executable string) string {
	$if macos {
		return os.norm_path(os.join_path(os.dir(executable), '..', 'Resources'))
	} $else {
		return os.join_path(os.dir(executable), 'resources')
	}
}

fn bundled_workbench_binary(executable string) string {
	$if macos {
		return os.join_path(workbench_resources(executable), 'runtime', 'vhttpd')
	} $else {
		return os.join_path(os.dir(executable), 'runtime', if os.user_os() == 'windows' {
			'vhttpd.exe'
		} else {
			'vhttpd'
		})
	}
}

pub fn local_environment_name() string {
	$if macos {
		return '本机 Mac'
	} $else $if windows {
		return '本机 Windows'
	} $else {
		return '本机 Linux'
	}
}

pub fn local_runtime_platform() string {
	$if linux {
		$if arm64 {
			return 'linux-arm64'
		} $else $if amd64 {
			return 'linux-amd64'
		}
	}
	$if macos {
		$if arm64 {
			return 'macos-arm64'
		}
	}
	return ''
}

// OpenSSH is an OS capability on Windows; do not assume Unix installation paths.
fn ssh_tool(executable string) string {
 $if windows {
  bundled := os.join_path(os.dir(os.executable()), 'tools', 'openssh', executable + '.exe')
  if os.is_file(bundled) { return bundled }
  system := os.join_path(os.getenv_opt('WINDIR') or { 'C:\\Windows' }, 'System32', 'OpenSSH', executable + '.exe')
  if os.is_file(system) { return system }
  return executable + '.exe'
 } $else { return '/usr/bin/' + executable }
}
