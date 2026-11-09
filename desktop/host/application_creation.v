module host

import app_bundle
import app_meta
import json2 as json
import net
import os

pub struct ApplicationTemplate {
pub:
	id string
	description string
	probe string
}

pub fn application_templates() []ApplicationTemplate {
	return [
		ApplicationTemplate{id: 'vjsx-http', description: 'vjsx HTTP handler', probe: 'GET / returns 200 with ok: true'},
		ApplicationTemplate{id: 'vjsx-api', description: 'vjsx JSON API', probe: 'GET /api/mcp-test returns 200 with ok: true'},
		ApplicationTemplate{id: 'pipeline', description: 'TOML listener, pipeline and fixed-response adapter', probe: 'GET /healthz returns 200 pipeline-ok'},
		ApplicationTemplate{id: 'wechat-cloud-functions', description: 'WeChat cloud function compatibility library and mini-program client', probe: 'GET /healthz invokes hello through the compatibility SDK'},
		ApplicationTemplate{id: 'codexbot', description: 'Codex Bot component with provider startup disabled until configured', probe: 'GET / returns 200 with app: codexbot-app-ts'},
	]
}

pub fn create_application_source(name string, template_id string, port int) !Project {
	if !app_bundle.valid_component_id(name) {
		return error('应用名称需为 1–64 位字母、数字、短横线或下划线。')
	}
	if port < 0 || port > 65535 {
		return error('应用端口范围为 1–65535；0 表示自动选择。')
	}
	mut template := ProjectTemplate{}
	for item in project_templates() {
		if item.id == template_id && item.id != 'environment' { template = item }
	}
	options := application_templates().filter(it.id == template_id)
	if options.len != 1 { return error('unknown_application_template') }
	mut actual_port := port
	if actual_port == 0 {
		mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
		actual_port = listener.addr()!.port()!
		listener.close()!
	}
	parent := os.join_path(workbench_data_dir(), 'application-sources')
	os.mkdir_all(parent, mode: 0o700)!
	root := os.join_path(os.real_path(parent), new_remote_id()!)
	os.mkdir(root, mode: 0o700)!
	mut created := false
	defer {
		if !created { os.rmdir_all(root) or {} }
	}
	component := match template_id {
		'pipeline' { $embed_file('../examples/pipeline-component/component.toml').to_string() }
		'wechat-cloud-functions' { $embed_file('../examples/wechat-cloud-component/component.toml').to_string() }
		'codexbot' { $embed_file('../../examples/codexbot-app-ts/component.toml').to_string().replace('port = 19883', 'port = 19903').replace('codexbot', 'component_demo') }
		else { $embed_file('../../examples/application-component/component.toml').to_string() }
	}
	text := component.replace('component_demo', name).replace('port = 19903', 'port = ${actual_port}')
	os.write_file(root + '/component.toml', text)!
	app_meta.initialize(root, name, 'component.toml')!
	mut files := match template_id {
		'pipeline' { map[string]string{} }
		'wechat-cloud-functions' { wechat_component_files() }
		'codexbot' { codexbot_component_files() }
		else { {'main.mjs': template.source_text.replace('"${template.source_name}"', json.encode(name))} }
	}
	entry_hint := match template_id {
		'vjsx-http', 'vjsx-api' { 'Edit main.mjs, the vjsx script entry.' }
		'pipeline' { 'Edit the listener, pipeline and adapter in component.toml.' }
		'wechat-cloud-functions' { 'Edit cloudfunctions/<name>/index.js and use app.mjs as the application entry.' }
		else { 'Use app.mts as the entry and config/bot.example.json as the provider reference.' }
	}
	files['AGENTS.md'] = '# Application development\n\n- Template: ${template_id}. Start at component.toml and follow the configured entries.\n- ${entry_hint}\n- Use vhttpd-develop and confirm compatibility with the selected runtime.\n- Smoke test: ${options[0].probe}.\n'
	for path, content in files {
		target := os.join_path(root, path)
		os.mkdir_all(os.dir(target), mode: 0o700)!
		os.write_file(target, content)!
	}
	project := project_from_file(root + '/component.toml', root)!
	created = true
	return project
}

// app.json is the public application entry; component TOML remains accepted
// for existing projects and for explicit source re-association.
pub fn application_source_from_file(path string) !Project {
 if os.file_name(path) == 'app.json' {
  root := os.real_path(os.dir(path))
  meta := app_meta.read(root)!
  return project_from_file(os.join_path(root,meta.entry),root)
 }
 return project_from_file(path,'')
}
