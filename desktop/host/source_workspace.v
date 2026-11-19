module host

import app_bundle
import config
import crypto.sha256
import json2 as json
import os
import net
import time
import toml

struct SourceWorkspacePlan {
	id         string
	root       string
	entry      string
	inode      u64
	dev        u64
	revision   string
	generation u64
	expires    i64
	files      map[string]string
}

fn source_directory(root string, relative string) !string {
	if os.is_link(root) || !os.is_dir(root) || os.real_path(root) != os.norm_path(root) {
		return error('source_authorization_root_changed')
	}
	if relative == '.' { return root }
	if !app_bundle.safe_path(relative) || os.is_abs_path(relative) || relative.contains(':') || relative.contains('\\') || relative.split('/').any(it.starts_with('.') || it in [
		'node_modules',
		'vendor',
		'bin',
		'dist',
	]) {
		return error('source_directory_outside_authorization')
	}
	mut path := root
	for part in relative.split('/') {
		path = os.join_path(path, part)
		if os.is_link(path) || !os.is_dir(path) {
			return error('source_directory_missing_or_symlink')
		}
	}
	if os.real_path(path) != path { return error('source_directory_changed') }
	return path
}

fn source_revision(root string) !string {
	return sha256.hexhash(json.encode(development_files(root)!))
}

fn source_config_boundary(root string, path string, mut seen map[string]bool) ! {
	if seen[path] { return }
	if seen.len >= 64 { return error('too_many_config_sources') }
	seen[path] = true
	development_target(root, os.path_rel(root, path)!.replace('\\', '/'))!
	if !os.exists(path) { return }
	text := development_read(path)!
	doc := toml.parse_text(text) or { return }
	includes := doc.decode[DevelopmentIncludes]() or { return }
	for include in includes.include {
		if os.is_abs_path(include) || include.contains('\\') {
			return error('source_include_outside_workspace')
		}
		source_config_boundary(root, os.norm_path(os.join_path(os.dir(path), include)), mut seen)!
	}
}

fn source_application(project Project) DevelopmentApplication {
	mut seen := map[string]bool{}
	if _ := source_config_boundary(project.workdir, project.config_path, mut seen) {
	} else {
		return DevelopmentApplication{ id: 'source-' + sha256.hexhash(project.workdir + '\n' + project.config_path)[..16], label: project.name, root: project.workdir, config_path: project.config_path }
	}
	mut listeners := []string{}
	if plan := config.load_runtime_plan_file(project.config_path) {
		mut control := ''
		if ref := plan.control.listener { control = ref.id }
		for id, _ in plan.listeners { if id != control { listeners << id } }
	}
	return DevelopmentApplication{ id: 'source-' + sha256.hexhash(project.workdir + '\n' + project.config_path)[..16], label: project.name, root: project.workdir, config_path: project.config_path, listeners: listeners }
}

fn (mut a DevelopmentAccess) bind_source(root string, project Project, application DevelopmentApplication, binary string, version string) ! {
	bound_stat := if project.workdir != '' { os.stat(project.workdir)! } else { os.Stat{} }
	a.mu.@lock()
	defer { a.mu.unlock() }
	if a.source_root == '' {
		stat := os.stat(root)!
		a.source_root = root
		a.source_inode = stat.inode
		a.source_dev = stat.dev
	}
	a.selection = DevelopmentSelection{ project: project, application: application, binary: binary, runtime_version: version, generation: a.selection.generation + 1, source_workspace: true, source_inode: bound_stat.inode, source_dev: bound_stat.dev }
}

fn (a &DevelopmentAccess) source_authorization() !string {
	a.mu.@lock()
	defer { a.mu.unlock() }
	if a.source_root == '' || a.revoked { return error('source_workspace_session_required') }
	root := source_directory(a.source_root, '.')!
	stat := os.stat(root)!
	if stat.inode != a.source_inode || stat.dev != a.source_dev {
		return error('source_authorization_root_changed')
	}
	return root
}

fn (mut d DevelopmentState) open_source_workspace(mut m Manager, call DevelopmentCall) !string {
	if !isnil(m.process) || m.phase in [.starting, .running, .stopping] {
		return error('stop_current_runtime_first')
	}
	if os.is_link(call.directory) || !os.is_dir(call.directory) {
		return error('source_directory_missing_or_symlink')
	}
	root := os.real_path(call.directory)
	project := Project{ name: os.file_name(root), workdir: root, config_path: os.join_path(root, 'vhttpd.toml'), source_workspace: true }
	mut seen := map[string]bool{}
	source_config_boundary(root, project.config_path, mut seen)!
	m.select_project(project)!
	mut access := call.access
	runtime := inspect_runtime(call.binary, os.executable(), RuntimeJob{})
	access.bind_source(root, project, source_application(project), call.binary, runtime.version)!
	d.previews.clear()
	d.applied.clear()
	d.source_plans.clear()
	return source_workspace_context(m, access)!
}

fn source_workspace_context(m &Manager, access &DevelopmentAccess) !string {
	root := access.source_authorization()!
	s := access.selection()
	bound := s.application.id != ''
	mut state := if bound { 'missing' } else { 'unbound' }
	stat := if bound { os.stat(s.project.workdir) or { os.Stat{} } } else { os.Stat{} }
	identity_ok := !bound || (stat.inode == s.source_inode && stat.dev == s.source_dev)
	mut seen := map[string]bool{}
	safe := if bound && identity_ok {
		if _ := source_config_boundary(s.project.workdir, s.project.config_path, mut seen) {
			true
		} else {
			false
		}
	} else {
		true
	}
	if bound && !identity_ok {
		state = 'directory_changed'
	} else if bound && !safe {
		state = 'configuration_outside_workspace'
	}
	if bound && identity_ok && safe && os.is_file(s.project.config_path) {
		state = if _ := config.load_runtime_plan_file(s.project.config_path) {
			'configuration_valid'
		} else {
			'configuration_invalid'
		}
		if _ := inspect_project(s.project) { state = 'runnable_configuration' }
	}
	return json.encode({
		'mode':             json.Any('source_workspace')
		'authorization_id': json.Any(sha256.hexhash(root))
		'bound':            json.Any(bound)
		'installed':        json.Any(false)
		'workspace':        json.Any({
			'id':            json.Any(if bound { sha256.hexhash(s.project.workdir) } else { '' })
			'directory':     json.Any(if bound {
				os.path_rel(root, s.project.workdir)!.replace('\\', '/')
			} else {
				''
			})
			'configuration': json.Any(if bound {
				os.path_rel(s.project.workdir, s.project.config_path)!.replace('\\', '/')
			} else {
				''
			})
		})
		'target':           json.Any({
			'kind':                json.Any('local_source')
			'environment':         json.Any(s.project.name)
			'runtime_version':     json.Any(s.runtime_version)
			'phase':               json.Any(m.phase.str())
			'listeners':           json.Any(if bound && identity_ok && safe {
				source_application(s.project).listeners.map(json.Any(it))
			} else {
				[]json.Any{}
			})
			'configuration_state': json.Any(state)
			'affects':             json.Any('all_applications_in_source_project')
		})
		'binding_revision': json.Any(i64(s.generation))
		'guidance_topics':  json.Any(['project', 'workflow', 'develop', 'vjsx', 'pipeline',
			'wechat-cloud-functions', 'codexbot', 'deploy', 'debug'].map(json.Any(it)))
	})
}

fn (mut d DevelopmentState) source_workspace_request(mut m Manager, call DevelopmentCall, a DevelopmentArgs) !string {
	root := call.access.source_authorization()!
	s := call.access.selection()
	if call.tool == 'source_workspace_get' { return source_workspace_context(m, call.access)! }
	if !isnil(call.grant) { return error('local_source_binding_required') }
	if a.binding_revision != s.generation { return error('binding_changed: call context_get') }
	if !isnil(m.process) || m.phase in [.starting, .running, .stopping] {
		return error('stop_current_runtime_first')
	}
	if d.applied.len > 0 { return error('restore_or_discard_source_changes_before_rebinding') }
	if call.tool == 'source_workspace_unbind' {
		mut access := call.access
		access.bind_source(root, Project{}, DevelopmentApplication{}, s.binary, s.runtime_version)!
		m.select_project(Project{})!
		d.previews.clear()
		d.source_plans.clear()
		return source_workspace_context(m, access)!
	}
	if call.tool == 'source_workspace_prepare' {
		if d.source_plans.len >= 16 {
			return error('source_binding_plan_limit: close or unbind the workspace')
		}
		directory := if a.directory == '' { '.' } else { a.directory }
		target := source_directory(root, directory)!
		entry := if a.entry == '' { 'vhttpd.toml' } else { a.entry }
		path := development_target(target, entry)!
		if os.file_ext(path) != '.toml' { return error('source_configuration_toml_required') }
		mut files := map[string]string{}
		if a.template != '' {
			if entry != 'vhttpd.toml' || os.ls(target)!.len != 0 {
				return error('source_template_requires_empty_directory')
			}
			stage := os.join_path(workbench_data_dir(), 'source-previews')
			os.mkdir_all(stage, mode: 0o700)!
			project := create_project(CreateProjectOptions{ name: new_remote_id()!, parent_dir: stage, template: a.template })!
			defer { os.rmdir_all(project.workdir) or {} }
			for name in ['vhttpd.toml', 'main.mjs', '.gitignore'] {
				file := os.join_path(project.workdir, name)
				if os.is_file(file) { files[name] = os.read_file(file)! }
			}
			files['AGENTS.md'] = '# Source workspace\n\nThis directory is used in place, without installation. Entry: vhttpd.toml. Read guidance_get(workflow) and the selected runtime vjsx contract. Edit main.mjs for the script templates. Stop, restore and verify through the MCP changes workflow.\n'
		}
		if os.is_file(path) {
			mut seen := map[string]bool{}
			source_config_boundary(target, path, mut seen)!
		}
		stat := os.stat(target)!
		p := SourceWorkspacePlan{ id: new_remote_id()!, root: target, entry: entry, inode: stat.inode, dev: stat.dev, revision: source_revision(target)!, generation: s.generation, expires: time.now().unix() + 300, files: files }
		d.source_plans[p.id] = p
		return json.encode({
			'plan_id':            json.Any(p.id)
			'directory':          json.Any(directory)
			'configuration':      json.Any(entry)
			'initialize':         json.Any(files.len > 0)
			'files_to_create':    json.Any(files.keys().map(json.Any(it)))
			'source_revision':    json.Any(p.revision)
			'installed':          json.Any(false)
			'expires_in_seconds': json.Any(300)
		})
	}
	if call.tool != 'source_workspace_bind' { return error('unknown_source_workspace_tool') }
	p := d.source_plans[a.id] or { return error('unknown_source_binding_plan') }
	if p.generation != s.generation || time.now().unix() >= p.expires {
		return error('source_binding_plan_expired_or_stale')
	}
	target := source_directory(root, os.path_rel(root, p.root)!.replace('\\', '/'))!
	stat := os.stat(target)!
	if stat.inode != p.inode || stat.dev != p.dev || source_revision(target)! != p.revision {
		return error('source_workspace_changed: prepare again')
	}
	if p.files.len > 0 && os.ls(target)!.len != 0 {
		return error('source_template_requires_empty_directory')
	}
	mut written := []string{}
	mut completed := false
	defer {
		if !completed {
			for file in written {
				if current := os.read_file(file) {
					if current == p.files[os.file_name(file)] { os.rm(file) or {} }
				}
			}
		}
	}
	for name, content in p.files {
		file := app_bundle.safe_target(target, name)!
		fd := create_project_file(file)!
		written << file
		write_project_contents(fd, content)!
	}
	project := Project{ name: os.file_name(target), config_path: development_target(target, p.entry)!, workdir: target, source_workspace: true }
	if os.is_file(project.config_path) {
		mut seen := map[string]bool{}
		source_config_boundary(target, project.config_path, mut seen)!
	}
	m.select_project(project)!
	mut access := call.access
	access.bind_source(root, project, source_application(project), s.binary, s.runtime_version)!
	d.previews.clear()
	d.source_plans.clear()
	completed = true
	return source_workspace_context(m, access)!
}

fn (mut d DevelopmentState) execute_source_workspace(mut m Manager, call DevelopmentCall) !string {
	selection := call.access.selection()
	root := call.access.source_authorization()!
	a := json.decode[DevelopmentArgs](call.arguments)!
	if call.tool != 'context_get' && a.binding_revision != selection.generation {
		return error('binding_changed: call context_get')
	}
	if !isnil(call.grant) && call.generation != selection.generation {
		return error('binding_changed: call context_get')
	}
	if call.tool.starts_with('source_workspace_') {
		return d.source_workspace_request(mut m, call, a)!
	}
	if selection.application.id == '' {
		if call.tool == 'context_get' { return source_workspace_context(m, call.access)! }
		if call.tool == 'guidance_get' && a.topic in ['workflow', 'pipeline', 'wechat-cloud-functions',
			'codexbot', 'deploy', 'debug'] {
			return desktop_development_guidance(selection, a.topic, call.desktop_version)!
		}
		if call.tool == 'templates_list' { return json.encode(project_templates()) }
		return error('source_workspace_unbound: prepare and bind a source directory')
	}
	if m.project != selection.project {
		return error('source_runtime_selection_changed: rebind in Desktop')
	}
	if call.tool == 'runtime_stop' {
		m.installation_stop()!
		return '{"stopped":true}'
	}
	if call.tool == 'changes_discard' {
		d.previews.delete(a.id)
		d.applied.delete(a.id)
		return '{"discarded":true,"files_unchanged":true}'
	}
	stat := os.stat(selection.project.workdir)!
	if stat.inode != selection.source_inode || stat.dev != selection.source_dev {
		return error('source_directory_identity_changed: prepare a fresh binding')
	}
	source_directory(root, os.path_rel(root, selection.project.workdir)!.replace('\\', '/'))!
	development_target(selection.project.workdir, os.path_rel(selection.project.workdir, selection.project.config_path)!.replace('\\', '/'))!
	mut seen := map[string]bool{}
	source_config_boundary(selection.project.workdir, selection.project.config_path, mut seen)!
	d.application = source_application(selection.project)
	d.remember_secrets(m)
	value := d.dispatch(mut m, call)!
	d.remember_secrets(m)
	return value
}

fn development_source_guard(m &Manager, p DevelopmentPreview) !&net.TcpListener {
	if !p.source_workspace { return development_guard(m)! }
	if !isnil(m.process) || m.phase in [.starting, .running, .stopping] {
		return error('stop_runtime_before_editing')
	}
	if m.info.admin_port > 0 { return development_guard(m)! }
	mut overrides := map[string]string{}
	for file in p.files {
		if os.file_ext(file.path) == '.toml' {
			overrides[development_target(p.project.workdir, file.path)!] = file.after
		}
	}
	if !os.is_file(p.project.config_path) && p.project.config_path !in overrides {
		return unsafe { nil }
	}
	plan := config.load_runtime_plan_with_overrides(p.project.config_path, overrides)!
	if ref := plan.control.listener {
		l := plan.listeners[ref.id] or { return error('invalid_source_control_listener') }
		if l.protocol != 'http' || l.tls.enabled || l.host !in ['127.0.0.1', 'localhost', '::1'] || l.port < 1 || l.port > 65535 {
			return error('local_source_control_required')
		}
		return net.listen_tcp(.ip, '${url_host(l.host)}:${l.port}') or { return error('runtime_admin_port_in_use') }
	}
	return unsafe { nil }
}
