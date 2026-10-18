module host

import config
import json2
import os

pub struct Project {
pub:
	name        string
	config_path string
	workdir     string
}

pub struct ProjectInfo {
pub:
	admin_host string
	admin_port int
	admin_url  string
	app_url    string
	entry      string
	executor   string
	// Never persisted or included in diagnostics.
	state_root string
	config_token string
}

pub fn project_from_file(path string, workdir string) !Project {
	if !os.is_file(path) || os.file_ext(path) != '.toml' {
		return error('请选择存在的 TOML 配置文件。')
	}
	file := os.real_path(path)
	root := if workdir == '' { os.dir(file) } else { os.real_path(workdir) }
	if !os.is_dir(root) {
		return error('项目工作目录不存在。')
	}
	return Project{
		name:        os.file_name(root)
		config_path: file
		workdir:     root
	}
}

// Use the same parser/compiler as vhttpd: includes, variable expansion and
// v1 compatibility must not be reimplemented by the desktop application.
pub fn inspect_project(project Project) !ProjectInfo {
	plan := config.load_runtime_plan_file(project.config_path)!
	legacy := config.load_vhttpd_config(['--config', project.config_path])!
	mut bind_host := legacy.admin.host
	mut port := legacy.admin.port
	mut token := legacy.admin.token
	mut control_id := ''
	if ref := plan.control.listener {
		control_id = ref.id
		listener := plan.listeners[ref.id] or { return error('管理监听器不存在。') }
		if listener.protocol != 'http' || listener.tls.enabled {
			return error('此原型仅支持本机 HTTP 管理监听器。')
		}
		bind_host = listener.host
		port = listener.port
	}
	if plan.control.token != '' {
		token = plan.control.token
	}
	if bind_host !in ['127.0.0.1', 'localhost', '::1'] || port < 1 || port > 65535 {
		return error('管理监听器需绑定 localhost / loopback，端口范围为 1–65535。')
	}
	if token.trim_space() == '' {
		return error('请先在项目配置中设置非空的管理 token。')
	}
	mut app_url := ''
	for id, listener in plan.listeners {
		if id != control_id && listener.port > 0 && listener.protocol == 'http' {
			app_url = 'http://${business_url_host(listener.host)}:${listener.port}'
			break
		}
	}
	mut entry := ''
	mut executor := ''
	for _, engine in plan.engines {
		executor = engine.kind
		entry = engine.options.strings['app_entry'] or { engine.options.strings['entry'] or { '' } }
		break
	}
	return ProjectInfo{
		state_root: if plan.observability.event_log != '' {
			log_dir := os.dir(plan.observability.event_log)
			if os.is_abs_path(log_dir) { os.join_path(log_dir, 'admin') } else { os.join_path(project.workdir, log_dir, 'admin') }
		} else { os.join_path(project.workdir, '.var', 'vhttpd', 'admin') }
		admin_host:   bind_host
		admin_port:   port
		admin_url:    'http://${url_host(bind_host)}:${port}/admin/ui/'
		app_url:      app_url
		entry:        entry
		executor:     executor
		config_token: token
	}
}

fn url_host(bind_host string) string {
	return if bind_host.contains(':') { '[${bind_host}]' } else { bind_host }
}

fn business_url_host(bind_host string) string {
	return match bind_host {
		'', '0.0.0.0' { '127.0.0.1' }
		'::' { '[::1]' }
		else { url_host(bind_host) }
	}
}

pub fn load_projects(path string, defaults []Project) ![]Project {
	if !os.exists(path) {
		return defaults
	}
	return json2.decode[[]Project](os.read_file(path)!)!
}

pub fn save_projects(path string, projects []Project) ! {
	os.mkdir_all(os.dir(path))!
	tmp := path + '.tmp'
	os.write_file(tmp, json2.encode(projects,
		prettify:       true
		legacy_layout:  true
		escape_unicode: true
		time_as_unix:   true
	))!
	os.mv(tmp, path)!
}
