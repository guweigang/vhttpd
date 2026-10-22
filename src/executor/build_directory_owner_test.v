module executor

import os
import time

fn build_owner_fixture() string {
	root := os.join_path(os.temp_dir(), 'vhttpd-build-owner-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn test_build_directory_reservations_with_same_prefix_are_independent() {
	root := build_owner_fixture()
	defer { os.rmdir_all(root) or {} }
	mut first := VjsxBuildDirectory.reserve(os.join_path(root, 'lane')) or { panic(err) }
	mut second := VjsxBuildDirectory.reserve(os.join_path(root, 'lane')) or { panic(err) }
	assert first.path != second.path
	marker := os.join_path(second.path, 'owned')
	os.write_file(marker, 'second') or { panic(err) }
	first.release()
	assert os.read_file(marker) or { panic(err) } == 'second'
	second.release()
	assert !os.exists(first.path)
	assert !os.exists(second.path)
	assert os.is_dir(root)
}

fn test_released_build_directory_cannot_remove_reused_path() {
	root := build_owner_fixture()
	defer { os.rmdir_all(root) or {} }
	mut owner := VjsxBuildDirectory.reserve(os.join_path(root, 'lane')) or { panic(err) }
	mut alias := owner
	owner.release()
	os.mkdir(owner.path) or { panic(err) }
	marker := os.join_path(owner.path, 'new-owner')
	os.write_file(marker, 'keep') or { panic(err) }
	alias.release()
	assert os.exists(marker)
}

fn test_concurrent_build_reservations_and_duplicate_release() {
	root := build_owner_fixture()
	defer { os.rmdir_all(root) or {} }
	prefix := os.join_path(root, 'lane')
	directories := chan &VjsxBuildDirectory{cap: 64}
	mut jobs := []thread{}
	for _ in 0 .. 16 {
		jobs << spawn fn [prefix, directories] () {
			for _ in 0 .. 4 {
				owner := VjsxBuildDirectory.reserve(prefix) or { panic(err) }
				directories <- owner
			}
		}()
	}
	jobs.wait()
	mut paths := map[string]bool{}
	mut releases := []thread{}
	for _ in 0 .. 64 {
		mut owner := <-directories
		assert !paths[owner.path]
		paths[owner.path] = true
		assert os.is_dir(owner.path)
		for _ in 0 .. 2 {
			releases << spawn fn [mut owner] () { owner.release() }()
		}
	}
	releases.wait()
	for path, _ in paths {
		assert !os.exists(path)
	}
	assert os.is_dir(root)
}

fn build_owner_executor_pair(ext string, source string) {
	root := build_owner_fixture()
	defer { os.rmdir_all(root) or {} }
	source_root := os.join_path(root, 'source')
	os.mkdir(source_root) or { panic(err) }
	entry := os.join_path(source_root, 'app.${ext}')
	os.write_file(entry, source) or { panic(err) }
	config := VjsxRuntimeFacadeConfig{
		app_entry:       entry
		module_root:     source_root
		signature_root:  source_root
		build_root:      os.join_path(root, 'cache')
		runtime_profile: 'script'
		thread_count:    1
	}
	first := new_inproc_vjsx_executor(config)
	second := new_inproc_vjsx_executor(config)
	defer {
		first.close()
		second.close()
	}
	first.ensure_lane_host(0) or { panic(err) }
	second.ensure_lane_host(0) or { panic(err) }
	first_host := first.state.hosts[0]
	second_host := second.state.hosts[0]
	mut old_owner := first_host.build_directory or { panic('missing first owner') }
	second_owner := second_host.build_directory or { panic('missing second owner') }
	assert old_owner.path != second_owner.path
	assert owns_build_directory(old_owner.path, old_owner.identity)
	assert owns_build_directory(second_owner.path, second_owner.identity)
	if ext == 'mts' {
		assert os.ls(old_owner.path) or { panic(err) }.len > 0
		assert os.ls(second_owner.path) or { panic(err) }.len > 0
	}
	marker := os.join_path(second_owner.path, 'owned-marker')
	os.write_file(marker, 'keep') or { panic(err) }
	assert !os.exists(config.lane_temp_root(0, first_host.source_signature))
	first.reset_lane_host(0)
	assert !os.exists(old_owner.path)
	assert os.exists(marker)
	mut result := second_host.call_entry('http', second_host.context().js_null()) or { panic(err) }
	assert result.to_string() == 'ready'
	result.free()
	first.ensure_lane_host(0) or { panic(err) }
	next_owner := first.state.hosts[0].build_directory or { panic('missing replacement owner') }
	assert next_owner.path != old_owner.path
	old_owner.release()
	assert os.is_dir(next_owner.path)
	first.close()
	assert !os.exists(next_owner.path)
	assert os.is_dir(second_owner.path)
	second.close()
	assert !os.exists(second_owner.path)
}

fn test_module_executors_and_replacement_own_separate_build_directories() {
	build_owner_executor_pair('mts', "export function http() { return 'ready'; }")
}

fn test_script_executors_use_injected_owned_build_directory() {
	build_owner_executor_pair('js', "globalThis.__vhttpd_handle = () => 'ready';")
}

fn test_failed_session_creation_releases_reserved_directory() {
	root := build_owner_fixture()
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.mjs')
	cache := os.join_path(root, 'cache')
	os.write_file(entry, 'export function http() {}') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		app_entry:       entry
		module_root:     root
		build_root:      cache
		runtime_profile: 'invalid-build-owner-profile'
		thread_count:    1
	})
	defer { exec.close() }
	mut failed := false
	exec.ensure_lane_host(0) or { failed = true }
	assert failed
	assert os.ls(cache) or { panic(err) }.len == 0
	assert exec.state.hosts[0].build_directory == none
}

fn test_failed_entry_bootstrap_releases_own_directory_and_preserves_peer() {
	root := build_owner_fixture()
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.js')
	cache := os.join_path(root, 'cache')
	os.write_file(entry, "throw new Error('bootstrap failed');") or { panic(err) }
	mut peer := VjsxBuildDirectory.reserve(os.join_path(cache, 'peer')) or { panic(err) }
	marker := os.join_path(peer.path, 'keep')
	os.write_file(marker, 'peer') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		app_entry:       entry
		module_root:     root
		signature_root:  root
		build_root:      cache
		runtime_profile: 'script'
		thread_count:    1
	})
	defer {
		exec.close()
		peer.release()
	}
	mut failed := false
	exec.ensure_lane_host(0) or { failed = true }
	assert failed
	assert os.ls(cache) or { panic(err) }.len == 1
	assert os.exists(marker)
	assert exec.state.hosts[0].build_directory == none
	assert exec.state.lane_wakeup_owners.len == 0
}

fn test_build_directory_reservation_preserves_invalid_parent_file() {
	root := build_owner_fixture()
	defer { os.rmdir_all(root) or {} }
	parent := os.join_path(root, 'file')
	os.write_file(parent, 'keep') or { panic(err) }
	if _ := VjsxBuildDirectory.reserve(os.join_path(parent, 'lane')) {
		assert false, 'a regular file cannot be a build directory parent'
	}
	assert os.read_file(parent) or { panic(err) } == 'keep'
}
