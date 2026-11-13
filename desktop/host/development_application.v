module host

import app_bundle
import app_meta
import config
import crypto.sha256
import json2 as json
import os
import toml

pub struct DevelopmentApplication {
pub:
	id          string
	label       string
	root        string
	config_path string
	listeners   []string
}

fn development_group(group string, id string) string {
	if group.starts_with('site:') { return group.all_after('site:').trim_space() }
	if group.trim_space() != '' { return group.trim_space().split('.')[0] }
	clean := id.trim_space()
	if clean.contains('/') { return clean.split('/')[0] }
	if clean.contains('.') { return clean.split('.')[0] }
	return if clean == '' { 'default' } else { clean }
}

// Discover from configuration, so stopped environments are also selectable.
pub fn development_applications(project Project) ![]DevelopmentApplication {
	plan := config.load_runtime_plan_file(project.config_path)!
	sources := config.runtime_config_sources(project.config_path)!
	mut apps := []DevelopmentApplication{}
	for source in sources {
		doc := toml.parse_text(development_read(source.path)!)!
		cfg := doc.decode[config.V2Config]()!
		if cfg.engines.len == 0 {
			// An explicitly identified component may consist only of pipelines.
			meta := app_meta.read(os.dir(source.path)) or { continue }
			if meta.entry != os.file_name(source.path) { continue }
		}
		mut ids := []string{}
		for p in cfg.pipelines {
			id := development_group(p.group, p.id)
			if id !in ids { ids << id }
		}
		// Shared source directories cannot be safely assigned to one application.
		if ids.len != 1 { continue }
		id := ids[0]
		root := os.dir(source.path)
		development_target(project.workdir, os.path_rel(project.workdir, source.path)!.replace('\\', '/'))!
		if apps.any(it.id == id || it.root == root) {
			return error('应用源码归属不明确，请整理为独立应用。')
		}
		listeners := plan.pipelines.filter(development_group(it.group, it.id) == id && it.ingress.domain == .listener).map(it.ingress.id)
		apps << DevelopmentApplication{
			id:          id
			label:       if root == project.workdir {
				project.name
			} else {
				id
			}
			root:        root
			config_path: source.path
			listeners:   listeners
		}
	}
	return apps
}

pub struct DevelopmentSelection {
pub:
	source_inode     u64
	source_dev       u64
	source_workspace bool
	project          Project
	application      DevelopmentApplication
	binary           string
	runtime_version  string
	generation       u64
}

pub fn (a &DevelopmentAccess) selection() DevelopmentSelection {
	a.mu.@lock()
	defer { a.mu.unlock() }
	return a.selection
}

fn (mut a DevelopmentAccess) bind(project Project, application DevelopmentApplication, binary string, version string) {
	a.mu.@lock()
	defer { a.mu.unlock() }
	if binary != '' && binary !in a.runtime_paths {
		a.runtime_paths << binary
		if a.runtime_paths.len > 64 { a.runtime_paths.delete(0) }
	}
	a.selection = DevelopmentSelection{ project: project, application: application, binary: binary, runtime_version: version, generation: a.selection.generation + 1 }
}

fn (mut d DevelopmentState) select_application(mut m Manager, call DevelopmentCall) !string {
	apps := development_applications(call.project)!
	selected := apps.filter(it.id == call.application)
	if selected.len != 1 {
		return error('应用不存在或没有独立的源码归属，请重新选择。')
	}
	if call.directory != '' && (os.is_link(call.directory) || os.norm_path(call.directory) != os.real_path(call.directory) || call.directory != selected[0].root) {
		return error('workspace_directory_mismatch')
	}
	if m.project != call.project { m.select_project(call.project)! }
	d.previews.clear()
	mut access := call.access
	runtime := inspect_runtime(call.binary, os.executable(), RuntimeJob{})
	access.bind(call.project, selected[0], call.binary, runtime.version)
	return json.encode(selected[0])
}

fn (d &DevelopmentState) file_root(m &Manager) string {
	return if d.application.root != '' { d.application.root } else { m.project.workdir }
}

fn (d &DevelopmentState) file_target(m &Manager, relative string) !string {
	root := d.file_root(m)
	path := development_target(root, relative)!
	if d.application.root != '' && !d.source_workspace {
		// A legacy root application must not grant access to installed siblings.
		for app in development_applications(m.project)! {
			if app.id != d.application.id && (path == app.root || path.starts_with(app.root + os.path_separator)) {
				return error('file_belongs_to_another_application')
			}
		}
	}
	return path
}

fn (d &DevelopmentState) application_files(m &Manager) ![]DevelopmentFile {
	mut result := []DevelopmentFile{}
	for file in development_files(d.file_root(m))! {
		if _ := d.file_target(m, file.path) { result << file }
	}
	return result
}

fn development_bound_context(m &Manager, selection DevelopmentSelection) string {
	app := selection.application
	return json.encode({
		'workspace':        json.Any({
			'id':            json.Any(sha256.hexhash(app.root))
			'application':   json.Any(app.id)
			'configuration': json.Any(os.file_name(app.config_path))
		})
		'target':           json.Any({
			'id':              json.Any(sha256.hexhash(selection.project.config_path + '\n' + app.id))
			'kind':            json.Any('local')
			'environment':     json.Any(selection.project.name)
			'application':     json.Any(app.id)
			'runtime_version': json.Any(selection.runtime_version)
			'phase':           json.Any(m.phase.str())
			'affects':         json.Any('all_applications_in_environment')
			'listeners':       json.Any(app.listeners.map(json.Any(it)))
		})
		'binding_revision': json.Any(i64(selection.generation))
		'guidance_topics':  json.Any(['project', 'develop', 'vjsx', 'workflow', 'pipeline',
			'wechat-cloud-functions', 'codexbot', 'deploy', 'debug'].map(json.Any(it)))
		'templates':        json.Any(application_templates().map(json.Any(it.id)))
	})
}

fn (d &DevelopmentState) guidance(m &Manager, selection DevelopmentSelection, topic string, version string) !string {
	if topic in ['workflow', 'pipeline', 'wechat-cloud-functions', 'codexbot', 'deploy', 'debug'] {
		return desktop_development_guidance(selection, topic, version)!
	}
	content := match topic {
		'project' {
			_ := d.file_target(m, os.file_name(selection.application.config_path))!
			path := app_bundle.safe_target(d.file_root(m), 'AGENTS.md')!
			if os.exists(path) { development_read(path)! } else { '' }
		}
		'develop', 'vjsx' { return development_package_guidance(selection, topic)! }
		else { return error('unknown_guidance_topic') }
	}
	return json.encode({
		'topic':                  topic
		'content':                content
		'source':                 'AGENTS.md'
		'target_runtime_version': selection.runtime_version
	})
}

fn desktop_development_guidance(selection DevelopmentSelection, topic string, version string) !string {
	content := match topic {
		'workflow' {
			$embed_file('../../src/development_guidance/vhttpd-workbench/references/develop.md').to_string()
		}
		'pipeline' {
			$embed_file('../../src/development_guidance/contracts/pipeline.md').to_string()
		}
		'wechat-cloud-functions' {
			$embed_file('../../src/development_guidance/contracts/wechat-cloud-functions.md').to_string()
		}
		'codexbot' {
			$embed_file('../../src/development_guidance/contracts/codexbot.md').to_string()
		}
		'deploy' { $embed_file('../../src/development_guidance/vhttpd-workbench/references/deploy.md').to_string() }
		'debug' { $embed_file('../../src/development_guidance/vhttpd-workbench/references/debug.md').to_string() }
		else { return error('unknown_guidance_topic') }
	}
	return json.encode({
		'topic':                  topic
		'source':                 'desktop_package'
		'guidance_version':       match topic { 'workflow' { '3' } 'deploy', 'debug' { '2' } else { '1' } }
		'desktop_version':        version
		'target_runtime_version': selection.runtime_version
		'content':                content
	})
}

fn development_package_guidance(selection DevelopmentSelection, topic string) !string {
	if selection.runtime_version == '' || !os.is_executable(selection.binary) {
		return error('runtime_guidance_unavailable: select a versioned runtime package')
	}
	body := (RuntimeJob{}).command(selection.binary, ['--development-guide', topic], 5000) or {
		return error('runtime_guidance_unavailable: this package could not provide development guidance')
	}
	guide := json.decode[map[string]string](body) or {
		return error('runtime_guidance_unavailable: invalid runtime package response')
	}
	if guide['topic'] != topic || guide['source'] != 'runtime_package' || guide['content'] == '' {
		return error('runtime_guidance_unavailable: invalid runtime package response')
	}
	if guide['runtime_version'] != selection.runtime_version {
		return error('runtime_guidance_version_mismatch: rebind using the selected runtime package')
	}
	return json.encode(guide)
}
