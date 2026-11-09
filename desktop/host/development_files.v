module host

import app_bundle
import app_meta
import config
import crypto.sha256
import json2 as json
import os
import toml

struct DevelopmentIncludes {
	include []string
}

struct DevelopmentChangeView {
	path   string
	action string
	before string
	after  string
}

struct DevelopmentPrepared {
	id    string
	files []DevelopmentChangeView
	next  string
}

// Check file access boundaries before the normal config compiler reads includes.
// Syntax, merging, variables and semantic validation remain owned by config.
fn development_config_boundary(root string, path string, overrides map[string]string, mut seen map[string]bool) ! {
	if seen[path] { return }
	if seen.len >= 64 { return error('too_many_config_sources') }
	seen[path] = true
	development_target(root, os.path_rel(root, path)!.replace('\\', '/'))!
	text := overrides[path] or { development_read(path)! }
	doc := toml.parse_text(text)!
	includes := doc.decode[DevelopmentIncludes]()!
	for include in includes.include {
		if os.is_abs_path(include) || include.contains('\\') {
			return error('relative_project_include_required')
		}
		child := os.norm_path(os.join_path(os.dir(path), include))
		development_config_boundary(root, child, overrides, mut seen)!
	}
}

// Reuse the application package path boundary, with a narrower text-only surface.
fn development_target(root string, relative string) !string {
	if os.is_link(root) || !os.is_dir(root) || os.real_path(root) != os.norm_path(root) {
		return error('workspace_root_changed')
	}
	if !app_bundle.safe_path(relative) || os.is_abs_path(relative) || relative.contains(':') || relative.split('/').any(it.starts_with('.') || it in [
		'node_modules',
		'vendor',
		'bin',
		'dist',
	]) {
		return error('path_not_in_development_workspace')
	}
	if os.file_name(relative) != 'AGENTS.md' && os.file_ext(relative).to_lower() !in [
		'.toml',
		'.mjs',
		'.mts',
		'.js',
		'.ts',
		'.jsx',
		'.tsx',
		'.json',
		'.html',
		'.css',
		'.svg',
		'.txt',
	] {
		return error('unsupported_development_file')
	}
	return app_bundle.safe_target(root, relative)!
}

fn development_read(path string) !string {
	if !os.is_file(path) || os.is_link(path) || os.file_size(path) > 1024 * 1024 {
		return error('regular_text_file_up_to_1MiB_required')
	}
	value := os.read_file(path)!
	if value.contains('\x00') { return error('binary_file_not_supported') }
	return value
}

fn development_walk(root string, dir string, mut files []DevelopmentFile, depth int) ! {
	if depth > 16 { return error('workspace_too_deep') }
	mut names := os.ls(dir)!
	names.sort()
	for name in names {
		if name.starts_with('.') || app_bundle.excluded(name) || name in [
			'node_modules',
			'vendor',
			'bin',
			'dist',
		] {
			continue
		}
		path := os.join_path(dir, name)
		if os.is_link(path) { continue }
		if os.is_dir(path) {
			development_walk(root, path, mut files, depth + 1)!
			continue
		}
		rel := os.path_rel(root, path)!.replace('\\', '/')
		if _ := development_target(root, rel) {
			value := development_read(path)!
			files << DevelopmentFile{ path: rel, revision: sha256.hexhash(value), size: value.len }
			if files.len > 4096 { return error('workspace_too_many_files') }
		}
	}
}

fn development_files(root string) ![]DevelopmentFile {
	mut files := []DevelopmentFile{}
	development_walk(root, root, mut files, 0)!
	return files
}

fn development_matches(m &Manager, p DevelopmentPreview) ! {
	if p.project != m.project { return error('selected_project_changed') }
	baseline := if p.source_workspace {
		development_files(p.source_root)!
	} else {
		development_baseline(p.project, p.source_root)!
	}
	if baseline != p.baseline {
		return error('workspace_changed: read files and prepare again')
	}
}

// Application source ownership can be narrower than the process working directory.
// Track that source tree plus every environment config, without scanning siblings
// or unrelated repository artifacts. Shared configuration changes still conflict.
fn development_baseline(project Project, source_root string) ![]DevelopmentFile {
	mut files := []DevelopmentFile{}
	for file in development_files(source_root)! {
		path := os.join_path(source_root, file.path)
		files << DevelopmentFile{ ...file, path: os.path_rel(project.workdir, path)!.replace('\\', '/') }
	}
	mut configs := map[string]bool{}
	development_config_boundary(project.workdir, project.config_path, map[string]string{}, mut configs)!
	for path, _ in configs {
		relative := os.path_rel(project.workdir, path)!.replace('\\', '/')
		if files.any(it.path == relative) { continue }
		value := development_read(path)!
		files << DevelopmentFile{ path: relative, revision: sha256.hexhash(value), size: value.len }
	}
	files.sort(a.path < b.path)
	return files
}

fn (mut d DevelopmentState) prepare(m &Manager, edits []DevelopmentEdit) !string {
	if edits.len == 0 || edits.len > 32 { return error('changeset_requires_1_to_32_files') }
	if d.previews.len + d.applied.len >= 16 {
		return error('session_changeset_limit_reached: use changes_discard for previews or recovery records no longer needed')
	}
	mut files := []DevelopmentChange{}
	mut seen := map[string]bool{}
	mut total := 0
	for edit in edits {
		path := d.file_target(m, edit.path)!
		if seen[path] { return error('duplicate_change_path') }
		seen[path] = true
		exists := os.exists(path)
		before := if exists { development_read(path)! } else { '' }
		if (exists && edit.revision != sha256.hexhash(before)) || (!exists && edit.revision != '') {
			return error('file_revision_changed:' + edit.path)
		}
		after := d.reveal(edit.content)!
		if os.file_name(path) == '.vhttpd-installation.json' {
			return error('application_identity_is_protected')
		}
		if !d.source_workspace && path == os.join_path(d.file_root(m), 'app.json') {
			next_meta := app_meta.parse(after)!
			if exists {
				old_meta := app_meta.parse(before)!
				if next_meta.id != old_meta.id { return error('application_identity_is_protected') }
			}
		}
		if d.application.id != '' && !d.source_workspace && os.file_ext(path) == '.toml' {
			next_doc := toml.parse_text(after)!
			next_cfg := next_doc.decode[config.V2Config]()!
			if next_cfg.pipelines.any(development_group(it.group, it.id) != d.application.id) {
				return error('application_identity_is_protected')
			}
			if d.application.root == m.project.workdir {
				before_doc := toml.parse_text(before)!
				before_cfg := before_doc.decode[config.V2Config]()!
				if before_cfg.include != next_cfg.include {
					return error('environment_includes_are_protected')
				}
			}
			if d.application.root != m.project.workdir {
				app_bundle.validate_component_config(after)!
			} else if path != d.application.config_path {
				return error('environment_config_is_not_application_source')
			}
		}
		if after.contains('\x00') || after.len > 1024 * 1024 {
			return error('text_file_too_large_or_binary')
		}
		total += after.len + before.len
		if total > 4 * 1024 * 1024 { return error('changeset_too_large') }
		files << DevelopmentChange{
			path:    os.path_rel(m.project.workdir, path)!.replace('\\', '/')
			before:  before
			after:   after
			existed: exists
			mode:    if exists {
				int(os.stat(path)!.mode & 0o777)
			} else {
				0o600
			}
		}
	}
	source_root := d.file_root(m)
	p := DevelopmentPreview{
		source_workspace: d.source_workspace
		id:               new_remote_id()!
		application_id:   d.application.id
		source_root:      source_root
		project:          m.project
		files:            files
		baseline:         if d.source_workspace {
			development_files(source_root)!
		} else {
			development_baseline(m.project, source_root)!
		}
	}
	d.previews[p.id] = p
	mut views := []DevelopmentChangeView{}
	for file in files {
		views << DevelopmentChangeView{
			path:   os.path_rel(d.file_root(m), os.join_path(m.project.workdir, file.path))!.replace('\\', '/')
			action: if file.existed {
				'replace'
			} else {
				'add'
			}
			before: file.before
			after:  file.after
		}
	}
	return json.encode(DevelopmentPrepared{ id: p.id, files: views, next: 'changes_validate; runtime_stop; changes_apply; runtime_start; application_request' })
}

fn development_validate(m &Manager, p DevelopmentPreview) ! {
	development_matches(m, p)!
	mut overrides := map[string]string{}
	for file in p.files {
		if os.file_ext(file.path) == '.toml' {
			overrides[development_target(p.project.workdir, file.path)!] = file.after
		}
	}
	if p.source_workspace && !os.is_file(p.project.config_path) && p.project.config_path !in overrides {
		return
	}
	mut seen := map[string]bool{}
	development_config_boundary(p.project.workdir, p.project.config_path, overrides, mut seen)!
	config.load_runtime_plan_with_overrides(p.project.config_path, overrides)!
	// Management stays on the same local endpoint; preserve its credential. New
	// business listeners and application bindings remain editable.
	after := config.load_runtime_plan_with_overrides(p.project.config_path, overrides)!
	before := config.load_runtime_plan_file(p.project.config_path) or {
		if p.source_workspace { return }
		return err
	}
	if p.application_id != '' && !p.source_workspace && !after.pipelines.any(development_group(it.group, it.id) == p.application_id) {
		return error('application_identity_is_protected')
	}
	if p.application_id != '' && !p.source_workspace && (before.server != after.server || before.observability != after.observability || before.resources != after.resources || before.relays != after.relays || before.providers != after.providers) {
		return error('environment_settings_are_protected')
	}
	if !(p.source_workspace && before.control.listener == none && before.control.token == '') && before.control != after.control {
		return error('management_control_is_protected')
	}
	if control := before.control.listener {
		if before.listeners[control.id] != after.listeners[control.id] {
			return error('management_listener_is_protected')
		}
	}
}

fn development_verify_changes(root string, files []DevelopmentChange, after bool) ! {
	for file in files {
		path := development_target(root, file.path)!
		if after || file.existed {
			if development_read(path)! != (if after { file.after } else { file.before }) {
				return error('file_changed:' + file.path)
			}
		} else if os.exists(path) {
			return error('new_file_already_exists:' + file.path)
		}
	}
}

fn development_compensate(root string, files []DevelopmentChange) ! {
	// Verify the whole restore before writing anything. Never overwrite external edits.
	development_verify_changes(root, files, true)!
	for i := files.len - 1; i >= 0; i-- {
		file := files[i]
		path := development_target(root, file.path)!
		development_verify_changes(root, [file], true)!
		if file.existed {
			component_write(path, file.before.bytes(), file.mode)!
		} else {
			os.rm(path)!
		}
	}
}

fn development_apply(mut m Manager, p DevelopmentPreview) ! {
	mut guard := development_source_guard(m, p)!
	defer { if !isnil(guard) { guard.close() or {} } }
	lock_dir := os.join_path(if p.source_workspace {
		p.project.workdir
	} else {
		os.dir(p.project.config_path)
	}, '.desktop-runtime-lock')
	os.mkdir(lock_dir, mode: 0o700) or { return error('application_operation_in_progress') }
	defer { os.rmdir(lock_dir) or {} }
	development_validate(m, p)!
	development_verify_changes(p.project.workdir, p.files, false)!
	mut committed := []DevelopmentChange{}
	mut failure := ''
	for file in p.files {
		development_verify_changes(p.project.workdir, [file], false) or {
			failure = err.msg()
			break
		}
		path := development_target(p.project.workdir, file.path) or {
			failure = err.msg()
			break
		}
		component_write(path, file.after.bytes(), file.mode) or {
			failure = err.msg()
			break
		}
		committed << file
	}
	if failure == '' && (!p.source_workspace || os.is_file(p.project.config_path)) {
		config.load_runtime_plan_file(p.project.config_path) or { failure = err.msg() }
	}
	if failure != '' {
		development_compensate(p.project.workdir, committed) or { return error('changeset_restore_failed: ' + err.msg()) }
		return error('changeset_rejected_and_restored: ' + failure)
	}
	m.info = inspect_project(m.project) or {
		if p.source_workspace {
			ProjectInfo{}
		} else {
			return err
		}
	}
	m.message = 'MCP 开发变更已写入，运行环境已停止；请启动并验证业务响应。'
	m.log(m.message)
}

fn development_restore(mut m Manager, p DevelopmentPreview) ! {
	if m.project != p.project { return error('selected_project_changed') }
	mut guard := development_source_guard(m, p)!
	defer { if !isnil(guard) { guard.close() or {} } }
	lock_dir := os.join_path(if p.source_workspace {
		p.project.workdir
	} else {
		os.dir(p.project.config_path)
	}, '.desktop-runtime-lock')
	os.mkdir(lock_dir, mode: 0o700) or { return error('application_operation_in_progress') }
	defer { os.rmdir(lock_dir) or {} }
	development_compensate(p.project.workdir, p.files)!
	m.info = inspect_project(m.project) or {
		if p.source_workspace {
			ProjectInfo{}
		} else {
			return err
		}
	}
	m.message = 'MCP 开发变更已恢复；运行环境保持停止。'
	m.log(m.message)
}
