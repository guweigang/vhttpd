module executor

import os
import time

fn test_lane_destroy_releases_session_and_module_even_before_initialization() {
	root := os.join_path(os.temp_dir(), 'vhttpd-lane-handle-${os.getpid()}-${time.now().unix_micro()}')
	mut directory := VjsxBuildDirectory.reserve(root) or { panic(err) }
	owned_root := directory.path
	entry := os.join_path(owned_root, 'entry.mjs')
	os.write_file(entry, 'export default function() { return 42; }') or { panic(err) }
	mut session := InProcVjsxRuntimeSessionFactory.new(VjsxRuntimeFacadeConfig{
		app_entry:       entry
		module_root:     owned_root
		runtime_profile: 'script'
	}) or { panic(err) }
	mut binding_value := session.import_module(entry) or { panic(err) }
	mut binding := &binding_value
	mut host := VjsxLaneHost{ session: session, module_binding: binding, build_directory: directory }
	assert host.session_handle() != none
	assert host.module_handle() != none
	host.destroy()
	assert binding.is_closed()
	assert session.is_closed()
	assert host.session_handle() == none
	assert host.module_handle() == none
	assert !os.exists(owned_root)
	host.destroy()
}
