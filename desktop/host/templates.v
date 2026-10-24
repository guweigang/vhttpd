module host

import crypto.rand as crypto_rand
import json2
import net
import os

pub struct ProjectTemplate {
pub:
	id          string
	title       string
	description string
	config_text string
	source_text string
	source_name string
	web_port    string
	admin_port  string
}

pub fn project_templates() []ProjectTemplate {
	return [ProjectTemplate{
		id:          'vjsx-http'
		title:       'vjsx · HTTP 入门'
		description: '最小 HTTP 处理函数，返回 JSON；适合从零开始。'
		config_text: $embed_file('../examples/hello-vjsx/vhttpd.toml').to_string()
		source_text: $embed_file('../examples/hello-vjsx/main.mts').to_string()
		source_name: 'hello-vjsx'
		web_port:    '19881'
		admin_port:  '19981'
	}, ProjectTemplate{
		id:          'vjsx-api'
		title:       'vjsx · JSON API'
		description: '展示请求方法、路径与查询参数，适合 API 调试。'
		config_text: $embed_file('../examples/api-playground/vhttpd.toml').to_string()
		source_text: $embed_file('../examples/api-playground/main.mts').to_string()
		source_name: 'api-playground'
		web_port:    '19882'
		admin_port:  '19982'
	}]
}

pub struct CreateProjectOptions {
pub:
	name       string
	parent_dir string
	template   string
}

pub fn project_target(options CreateProjectOptions) !string {
	name := options.name.trim_space()
	if name.len < 1 || name.len > 64 {
		return error('项目名称需为 1–64 个字符。')
	}
	for i, ch in name.bytes() {
		if !(ch.is_letter() || ch.is_digit() || (i > 0 && ch in [`-`, `_`])) {
			return error('项目名称以字母或数字开头，仅使用字母、数字、短横线和下划线。')
		}
	}
	if !os.is_dir(options.parent_dir) {
		return error('请选择已存在的项目存放目录。')
	}
	return os.join_path(os.real_path(options.parent_dir), name)
}

// The templates are embedded so creation never depends on the example files
// beside the executable. All generated paths remain relative to the new project.
pub fn create_project(options CreateProjectOptions) !Project {
	mut template := ProjectTemplate{}
	for item in project_templates() {
		if item.id == options.template {
			template = item
			break
		}
	}
	if template.id == '' { return error('请选择支持的 vjsx 模板。') }
	target := project_target(options)!
	// mkdir is exclusive, including existing empty directories and symlinks.
	// Never use mkdir_all(target), or overwrite an existing project's files.
	os.mkdir(target) or { return error('无法创建项目目录（可能已存在或没有写入权限）：${target}') }
	mut completed := false
	mut written := []string{}
	defer {
		if !completed {
			// Remove only files written by this operation. Never recursively
			// delete a directory someone else may have populated concurrently.
			for path in written { os.rm(path) or {} }
			os.rmdir(target) or {}
		}
	}
	// Keep both sockets bound until generation completes: distinct ports even
	// under concurrent creations. They are suggestions, not reservations after
	// creation; normal startup checks still handle later port conflicts.
	mut web := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { web.close() or {} }
	mut admin := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { admin.close() or {} }
	web_port := web.addr()!.port()!
	admin_port := admin.addr()!.port()!
	credential := crypto_rand.bytes(32)!.hex()
	config_text := template.config_text
		.replace('entry = "main.mts"', 'entry = "main.mjs"')
		.replace('runtime_profile = "node"', 'runtime_profile = "script"')
		.replace('port = ${template.web_port}', 'port = ${web_port}')
		.replace('port = ${template.admin_port}', 'port = ${admin_port}')
		.replace('local-development-only', credential)
	source_text := template.source_text.replace('"${template.source_name}"', json2.encode(options.name.trim_space()))
	files := {
		'vhttpd.toml': config_text
		'main.mjs':    source_text
		'.gitignore':  'runtime.pid\nevents.ndjson\n'
	}
	for name, content in files {
		path := os.join_path(target, name)
		fd := create_project_file(path)!
		written << path
		write_project_contents(fd, content)!
	}
	project := project_from_file(os.join_path(target, 'vhttpd.toml'), target)!
	inspect_project(project)!
	completed = true
	return project
}
