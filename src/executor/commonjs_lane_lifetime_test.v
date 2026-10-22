module executor

import os
import time

fn cjs_lifetime_fixture(ext string, source string) (string, VjsxRuntimeFacadeConfig) {
	root := os.join_path(os.temp_dir(), 'vhttpd-cjs-lifetime-${os.getpid()}-${time.sys_mono_now()}')
	source_root := os.join_path(root, 'source')
	os.mkdir_all(source_root) or { panic(err) }
	entry := os.join_path(source_root, 'app.${ext}')
	os.write_file(entry, source) or { panic(err) }
	os.write_file(os.join_path(source_root, 'lazy.mjs'), "export const value = 'lazy-ready';") or { panic(err) }
	return root, VjsxRuntimeFacadeConfig{
		app_entry:       entry
		module_root:     source_root
		signature_root:  source_root
		build_root:      os.join_path(root, 'cache')
		runtime_profile: 'script'
		thread_count:    1
	}
}

fn cjs_lifetime_source() string {
	return "module.exports = {}; globalThis.__vhttpd_handle = async () => (await import('./lazy.mjs')).value;"
}

fn cjs_lifetime_call(host VjsxLaneHost) string {
	mut pending := host.call_entry('http', host.context().js_null()) or { panic(err) }
	defer { pending.free() }
	mut result := host.resolve_value(pending) or { panic(err) }
	defer { result.free() }
	return result.to_string()
}

fn test_commonjs_js_mirror_survives_bootstrap_and_deferred_import() {
	root, config := cjs_lifetime_fixture('js', cjs_lifetime_source())
	defer { os.rmdir_all(root) or {} }
	exec := new_inproc_vjsx_executor(config)
	defer { exec.close() }
	exec.ensure_lane_host(0) or { panic(err) }
	host := exec.state.hosts[0]
	owner := host.build_directory or { panic('missing directory owner') }
	assert os.is_file(os.join_path(owner.output_path(), '.complete'))
	assert cjs_lifetime_call(host) == 'lazy-ready'
	assert cjs_lifetime_call(host) == 'lazy-ready'
	exec.close()
	assert !os.exists(owner.path)
}

fn test_commonjs_js_rebuild_and_peer_keep_their_lazy_import_files() {
	root, config := cjs_lifetime_fixture('js', cjs_lifetime_source())
	defer { os.rmdir_all(root) or {} }
	first := new_inproc_vjsx_executor(config)
	second := new_inproc_vjsx_executor(config)
	defer {
		first.close()
		second.close()
	}
	first.ensure_lane_host(0) or { panic(err) }
	second.ensure_lane_host(0) or { panic(err) }
	old := first.state.hosts[0].build_directory or { panic('missing old owner') }
	peer := second.state.hosts[0].build_directory or { panic('missing peer owner') }
	first.reset_lane_host(0)
	assert !os.exists(old.path)
	assert os.is_dir(peer.path)
	first.ensure_lane_host(0) or { panic(err) }
	next := first.state.hosts[0].build_directory or { panic('missing next owner') }
	assert next.path != old.path
	assert cjs_lifetime_call(second.state.hosts[0]) == 'lazy-ready'
	assert cjs_lifetime_call(first.state.hosts[0]) == 'lazy-ready'
	first.close()
	assert os.is_dir(peer.path)
	assert !os.exists(next.path)
}

fn test_explicit_cjs_entry_retains_same_deferred_import_lifetime() {
	root, config := cjs_lifetime_fixture('cjs', cjs_lifetime_source())
	defer { os.rmdir_all(root) or {} }
	exec := new_inproc_vjsx_executor(config)
	defer { exec.close() }
	exec.ensure_lane_host(0) or { panic(err) }
	assert cjs_lifetime_call(exec.state.hosts[0]) == 'lazy-ready'
}

fn test_commonjs_js_node_profile_retains_deferred_import_files() {
	root, original := cjs_lifetime_fixture('js', cjs_lifetime_source())
	defer { os.rmdir_all(root) or {} }
	config := VjsxRuntimeFacadeConfig{ ...original, runtime_profile: 'node' }
	exec := new_inproc_vjsx_executor(config)
	defer { exec.close() }
	exec.ensure_lane_host(0) or { panic(err) }
	assert cjs_lifetime_call(exec.state.hosts[0]) == 'lazy-ready'
}

fn test_plain_js_preserves_global_scope_and_does_not_resolve_unused_import() {
	source := "var laneCounter = 0; function unused() { return import('./absent.mjs'); } globalThis.__vhttpd_handle = () => String(++laneCounter);"
	root, config := cjs_lifetime_fixture('js', source)
	defer { os.rmdir_all(root) or {} }
	exec := new_inproc_vjsx_executor(config)
	defer { exec.close() }
	exec.ensure_lane_host(0) or { panic(err) }
	host := exec.state.hosts[0]
	assert cjs_lifetime_call(host) == '1'
	assert cjs_lifetime_call(host) == '2'
	value := host.context().eval('globalThis.laneCounter') or { panic(err) }
	assert value.to_string() == '2'
	value.free()
}

fn test_commonjs_js_evaluation_failure_cleans_reserved_mirror() {
	root, config := cjs_lifetime_fixture('js', "module.exports = {}; throw new Error('cjs-failed');")
	defer { os.rmdir_all(root) or {} }
	exec := new_inproc_vjsx_executor(config)
	defer { exec.close() }
	mut failed := false
	exec.ensure_lane_host(0) or {
		assert err.msg().contains('inproc_vjsx_executor_bootstrap_failed:')
		assert err.msg().contains('cjs-failed')
		failed = true
	}
	assert failed
	assert os.ls(config.build_root) or { panic(err) }.len == 0
	assert exec.state.hosts[0].build_directory == none
	assert exec.state.lane_wakeup_owners.len == 0
}

fn test_commonjs_js_resolution_failure_cleans_reserved_directory() {
	root, config := cjs_lifetime_fixture('js', "module.exports = require('./absent.cjs');")
	defer { os.rmdir_all(root) or {} }
	exec := new_inproc_vjsx_executor(config)
	defer { exec.close() }
	mut failed := false
	exec.ensure_lane_host(0) or { failed = true }
	assert failed
	assert os.ls(config.build_root) or { panic(err) }.len == 0
	assert exec.state.hosts[0].build_directory == none
	assert exec.state.lane_wakeup_owners.len == 0
}

fn test_module_lane_executes_owned_mirror_without_second_build() {
	root, config := cjs_lifetime_fixture('mjs', "export async function http() { return import.meta.url + '|' + (await import('./lazy.mjs')).value; }")
	defer { os.rmdir_all(root) or {} }
	exec := new_inproc_vjsx_executor(config)
	defer { exec.close() }
	exec.ensure_lane_host(0) or { panic(err) }
	host := exec.state.hosts[0]
	owner := host.build_directory or { panic('missing owner') }
	result := cjs_lifetime_call(host)
	assert result.contains(os.real_path(owner.path))
	assert result.ends_with('|lazy-ready')
	temporary := host.context().js_global('__vhttpd_lane_exports')
	assert temporary.is_undefined()
	temporary.free()
	// The scoped import bridge must be restored for later ordinary session imports.
	session := host.session_handle() or { panic('missing session') }
	mut ordinary := session.import_module(os.join_path(os.dir(config.app_entry), 'lazy.mjs')) or { panic(err) }
	value := ordinary.get_export('value') or { panic(err) }
	assert value.to_string() == 'lazy-ready'
	value.free()
	ordinary.close()
	exec.close()
	assert !os.exists(owner.path)
}
