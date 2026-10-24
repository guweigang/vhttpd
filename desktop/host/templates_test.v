module host

import net
import os
import time

fn test_create_templates_are_portable_and_have_distinct_local_ports() ! {
	dir := template_fixture_dir('create parent 中文')!
	defer { os.rmdir_all(dir) or {} }
	mut credentials := []string{}
	for i, template in project_templates() {
		project := create_project(CreateProjectOptions{ name: 'test-app-${i}', parent_dir: dir, template: template.id })!
		assert project.workdir == os.join_path(dir, 'test-app-${i}')
		assert project.name == 'test-app-${i}'
		info := inspect_project(project)!
		assert info.executor == 'vjsx'
		assert info.entry == os.join_path(project.workdir, 'main.mjs')
		assert info.config_token.len == 64
		assert info.config_token !in credentials
		credentials << info.config_token
		assert !info.app_url.ends_with(':${info.admin_port}')
		assert os.read_file(info.entry)!.contains('"test-app-${i}"')
		text := os.read_file(project.config_path)!
		assert !text.contains(dir)
		assert !text.contains('local-development-only')
		assert text.contains('runtime_profile = "script"')
		mut listener := net.listen_tcp(.ip, '127.0.0.1:${info.admin_port}')!
		listener.close()!
	}
}

fn test_existing_directory_and_files_are_never_overwritten() ! {
	dir := template_fixture_dir('no-overwrite')!
	defer { os.rmdir_all(dir) or {} }
	target := os.join_path(dir, 'existing')
	os.mkdir(target)!
	file := os.join_path(target, 'vhttpd.toml')
	os.write_file(file, 'keep my original configuration')!
	create_project(CreateProjectOptions{ name: 'existing', parent_dir: dir, template: 'vjsx-http' }) or {
		assert os.read_file(file)! == 'keep my original configuration'
		assert os.ls(target)!.len == 1
		return
	}
	assert false, 'Existing projects must be rejected'
}

fn test_invalid_name_or_template_never_creates_files() ! {
	dir := template_fixture_dir('invalid-create')!
	defer { os.rmdir_all(dir) or {} }
	for name in ['', '../escape', 'a/b', 'a\\b', '-leading', 'invalid name'] {
		mut rejected := false
		create_project(CreateProjectOptions{ name: name, parent_dir: dir, template: 'vjsx-http' }) or { rejected = true }
		assert rejected, name
	}
	mut rejected := false
	create_project(CreateProjectOptions{ name: 'valid', parent_dir: dir, template: 'unknown' }) or { rejected = true }
	assert rejected
	assert os.ls(dir)!.len == 0
}

fn test_symlink_target_is_rejected_without_modifying_destination() ! {
	dir := template_fixture_dir('symlink-create')!
	defer { os.rmdir_all(dir) or {} }
	os.mkdir(os.join_path(dir, 'original'))!
	os.symlink(os.join_path(dir, 'original'), os.join_path(dir, 'alias'))!
	mut rejected := false
	create_project(CreateProjectOptions{ name: 'alias', parent_dir: dir, template: 'vjsx-http' }) or { rejected = true }
	assert rejected
	assert os.ls(os.join_path(dir, 'original'))!.len == 0
}

fn test_exclusive_file_creation_preserves_existing_contents() ! {
	dir := template_fixture_dir('exclusive-file')!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'main.mts')
	os.write_file(path, 'keep original source')!
	create_project_file(path) or {
		assert os.read_file(path)! == 'keep original source'
		return
	}
	assert false, 'Concurrent files must never be truncated'
}

fn template_fixture_dir(label string) !string {
	path := os.join_path(os.temp_dir(), 'workbench-${label}-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path)!
	return os.real_path(path)
}
