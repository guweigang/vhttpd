module host

import crypto.sha256
import os
import time

fn test_package_plan_requires_matching_binding_and_action() {
	mut s := ServerSession{}
	r := McpPackageRequest{ tool: 'runtime_install_apply', deadline: time.now().unix() + 30 }
	s.begin_mcp_package(r, ServerWorker{}) or {
		assert err.msg().contains('invalid_package_plan')
		return
	}
	assert false
}

fn test_package_install_platform_must_match_destination() {
	s := ServerSession{}
	s.check_package_install_target('', 'unsupported') or {
		assert err.msg().contains('platform_mismatch')
		return
	}
	assert false
}

fn test_local_package_selection_requires_stopped_runtime_and_current_binding() {
	mut d := DevelopmentState{}
	mut m := Manager{ phase: .running }
	call := DevelopmentCall{ tool: '_runtime_package_select' }
	d.select_runtime_package(mut m, call) or {
		assert err.msg().contains('stale_binding_revision')
		return
	}
	assert false
}

fn test_official_install_without_selection_preserves_previous_choice() ! {
	archive := os.getenv('VHTTPD_MCP_PACKAGE_TEST_ARCHIVE')
	if archive == '' { return }
	root := os.join_path(os.temp_dir(), 'mcp-package-install-' + new_remote_id()!)
	previous := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root, true)
	defer {
		if value := previous {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(root)!
	os.write_file(os.join_path(root, 'runtime-selection.json'), '{"path":"retained-baseline"}')!
	expected := os.getenv('VHTTPD_MCP_PACKAGE_TEST_CHECKSUM')
	path := install_runtime_without_selection(archive, expected, '', RuntimeJob{})!
	assert os.is_executable(path)
	assert os.read_file(os.join_path(root, 'runtime-selection.json'))! == '{"path":"retained-baseline"}'
	install_runtime_without_selection(archive, '0'.repeat(64), '', RuntimeJob{}) or {
		assert os.read_file(os.join_path(root, 'runtime-selection.json'))! == '{"path":"retained-baseline"}'
		return
	}
	assert false
}

fn test_original_external_package_remains_available_after_switch() ! {
	root := os.join_path(os.temp_dir(), 'mcp-retained-packages-' + new_remote_id()!)
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	first := os.join_path(root, 'first')
	second := os.join_path(root, 'second')
	for path in [first, second] {
		os.write_file(path, '#!/bin/sh\nexit 0\n')!
		os.chmod(path, 0o700)!
	}
	mut access := &DevelopmentAccess{}
	access.bind(Project{}, DevelopmentApplication{}, first, 'one')
	access.bind(Project{}, DevelopmentApplication{}, second, 'two')
	paths := access.runtime_package_paths(second)!
	assert paths['sha256-' + sha256.hexhash(os.real_path(first))] == os.real_path(first)
	assert paths['sha256-' + sha256.hexhash(os.real_path(second))] == os.real_path(second)
}
