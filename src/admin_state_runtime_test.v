module main

import config
import os
import time

fn admin_state_runtime_test_root(name string) string {
	return os.join_path(os.temp_dir(), '${name}_${time.now().unix_micro()}')
}

fn admin_state_runtime_plan_text(body string) string {
	return admin_state_named_runtime_plan_text('web', 18080, body)
}

fn admin_state_named_runtime_plan_text(id string, port int, body string) string {
	return '
version = 2

[listeners.${id}]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}

[adapters.${id}]
kind = "fixed-response"

[adapters.${id}.options]
status = "200"
body = "${body}"

[[pipelines]]
id = "${id}"
ingress = "listener:${id}"
egress = "adapter:${id}"

[pipelines.match]
paths = ["*"]
'
}

fn test_admin_state_validate_and_diff_draft() {
	root := admin_state_runtime_test_root('vhttpd_admin_state_runtime')
	defer {
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(root) or { panic(err) }
	current_file := os.join_path(root, 'current.toml')
	event_log := os.join_path(root, 'events.ndjson')
	os.write_file(event_log, '') or { panic(err) }
	current_text := admin_state_runtime_plan_text('old')
	current_plan := config.load_runtime_plan_text(current_text, current_file) or { panic(err) }
	mut app := App{
		DataPlaneRuntime: DataPlaneRuntime{
			plan: current_plan
		}
		control_plane:    ControlPlaneRuntime{
			event_log: event_log
		}
	}

	app.admin_state_put_draft('draft_1', admin_state_runtime_plan_text('new')) or { panic(err) }
	validation := app.admin_state_validate_draft('draft_1')
	assert validation.ok
	assert validation.error == ''
	assert validation.schema_version == 2
	assert validation.counts.listeners == 1
	assert validation.counts.adapters == 1
	assert validation.counts.pipelines == 1

	preview := app.admin_state_diff_draft('draft_1') or { panic(err) }
	assert preview.config_path == 'draft:draft_1'
	assert preview.allowed
	assert preview.strategy == 'lightweight'
	assert preview.changed_pipelines == ['web']
}

fn test_admin_state_validate_draft_reports_compile_error() {
	root := admin_state_runtime_test_root('vhttpd_admin_state_runtime_error')
	defer {
		os.rmdir_all(root) or {}
	}
	os.mkdir_all(root) or { panic(err) }
	event_log := os.join_path(root, 'events.ndjson')
	os.write_file(event_log, '') or { panic(err) }
	mut app := App{
		control_plane: ControlPlaneRuntime{
			event_log: event_log
		}
	}
	app.admin_state_put_draft('bad', 'version = 2\n[listeners.web]\nprotocol = "http"\n') or {
		panic(err)
	}
	validation := app.admin_state_validate_draft('bad')
	assert !validation.ok
	assert validation.error != ''
}

fn test_admin_state_publish_draft_writes_include_and_keeps_main_config_valid() {
	root := admin_state_runtime_test_root('vhttpd_admin_state_publish')
	defer {
		os.rmdir_all(root) or {}
	}
	admin_dir := os.join_path(root, 'admin')
	os.mkdir_all(admin_dir) or { panic(err) }
	current_file := os.join_path(admin_dir, 'admin.toml')
	event_log := os.join_path(root, 'events.ndjson')
	os.write_file(event_log, '') or { panic(err) }
	os.write_file(current_file, admin_state_named_runtime_plan_text('admin', 18081, 'admin')) or {
		panic(err)
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		DataPlaneRuntime: DataPlaneRuntime{
			plan: current_plan
		}
		control_plane:    ControlPlaneRuntime{
			event_log: event_log
		}
	}
	app.admin_state_put_draft('app.demo.toml', admin_state_named_runtime_plan_text('demo', 18082,
		'demo')) or { panic(err) }

	result := app.admin_state_publish_draft('app.demo.toml', '../examples/demo/demo-v2.toml')
	assert result.ok
	assert result.config_path == current_file
	assert result.include_path == '../examples/demo/demo-v2.toml'
	assert result.updated_main
	assert os.exists(os.join_path(root, 'examples', 'demo', 'demo-v2.toml'))
	main_text := os.read_file(current_file) or { panic(err) }
	assert main_text.contains('"../examples/demo/demo-v2.toml"')
	plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	pipeline_ids := plan.pipelines.map(it.id)
	assert pipeline_ids.contains('admin')
	assert pipeline_ids.contains('demo')

	second := app.admin_state_publish_draft('app.demo.toml', '../examples/demo/demo-v2.toml')
	assert second.ok
	assert !second.updated_main
	second_main_text := os.read_file(current_file) or { panic(err) }
	assert second_main_text.count('"../examples/demo/demo-v2.toml"') == 1
}

fn test_admin_state_publish_draft_rejects_path_outside_project() {
	root := admin_state_runtime_test_root('vhttpd_admin_state_publish_outside')
	defer {
		os.rmdir_all(root) or {}
	}
	admin_dir := os.join_path(root, 'admin')
	os.mkdir_all(admin_dir) or { panic(err) }
	current_file := os.join_path(admin_dir, 'admin.toml')
	event_log := os.join_path(root, 'events.ndjson')
	os.write_file(event_log, '') or { panic(err) }
	os.write_file(current_file, admin_state_named_runtime_plan_text('admin', 18083, 'admin')) or {
		panic(err)
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		DataPlaneRuntime: DataPlaneRuntime{
			plan: current_plan
		}
		control_plane:    ControlPlaneRuntime{
			event_log: event_log
		}
	}
	app.admin_state_put_draft('outside', admin_state_named_runtime_plan_text('outside', 18084,
		'outside')) or { panic(err) }

	result := app.admin_state_publish_draft('outside', '../../outside.toml')
	assert !result.ok
	assert result.error.contains('admin_draft_publish_path_outside_project')
}

fn test_admin_state_config_file_draft_opens_include_and_publishes_to_source() {
	root := admin_state_runtime_test_root('vhttpd_admin_state_config_file_draft')
	defer {
		os.rmdir_all(root) or {}
	}
	admin_dir := os.join_path(root, 'admin')
	include_dir := os.join_path(root, 'examples', 'demo')
	os.mkdir_all(admin_dir) or { panic(err) }
	os.mkdir_all(include_dir) or { panic(err) }
	current_file := os.join_path(admin_dir, 'admin.toml')
	include_file := os.join_path(include_dir, 'demo-v2.toml')
	event_log := os.join_path(root, 'events.ndjson')
	os.write_file(event_log, '') or { panic(err) }
	os.write_file(current_file,
		'version = 2\n\ninclude = [\n  "../examples/demo/demo-v2.toml",\n]\n\n' +
		admin_state_named_runtime_plan_text('admin', 18085, 'admin').replace('version = 2\n\n', '')) or {
		panic(err)
	}
	os.write_file(include_file, admin_state_named_runtime_plan_text('demo', 18086, 'demo')) or {
		panic(err)
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		DataPlaneRuntime: DataPlaneRuntime{
			plan: current_plan
		}
		control_plane:    ControlPlaneRuntime{
			event_log: event_log
		}
	}

	files := app.admin_state_list_config_files()
	assert files.len == 2
	assert files.any(it.role == 'main' && it.path == current_file)
	assert files.any(it.role == 'include' && it.include_path == '../examples/demo/demo-v2.toml')

	draft := app.admin_state_open_config_file_draft('../examples/demo/demo-v2.toml')
	assert draft.ok
	assert draft.include_path == '../examples/demo/demo-v2.toml'
	assert draft.entry.value.contains('body = "demo"')
	validation := app.admin_state_validate_draft(draft.draft_id)
	assert validation.ok

	app.admin_state_put_draft(draft.draft_id, admin_state_named_runtime_plan_text('demo', 18086,
		'changed')) or { panic(err) }
	published := app.admin_state_publish_draft(draft.draft_id, '')
	assert published.ok
	assert !published.updated_main
	assert os.read_file(include_file) or { panic(err) }.contains('body = "changed"')
}

fn test_admin_state_source_file_draft_opens_and_publishes_typescript() {
	root := admin_state_runtime_test_root('vhttpd_admin_state_source_file_draft')
	defer {
		os.rmdir_all(root) or {}
	}
	admin_dir := os.join_path(root, 'admin')
	app_dir := os.join_path(root, 'examples', 'plugin')
	os.mkdir_all(admin_dir) or { panic(err) }
	os.mkdir_all(app_dir) or { panic(err) }
	current_file := os.join_path(admin_dir, 'admin.toml')
	plugin_file := os.join_path(app_dir, 'app.mts')
	event_log := os.join_path(root, 'events.ndjson')
	os.write_file(event_log, '') or { panic(err) }
	os.write_file(plugin_file, 'export function handler() { return "old"; }\n') or { panic(err) }
	os.write_file(current_file, '
version = 2

[listeners.plugin]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18087

[engines.plugin]
kind = "vjsx"
entry = "../examples/plugin/app.mts"
module_root = "../examples/plugin"

[adapters.plugin]
kind = "http-handler"
engine = "engine:plugin"

[[pipelines]]
id = "plugin.app"
ingress = "listener:plugin"
egress = "adapter:plugin"

[pipelines.match]
paths = ["*"]
') or {
		panic(err)
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		DataPlaneRuntime: DataPlaneRuntime{
			plan: current_plan
		}
		control_plane:    ControlPlaneRuntime{
			event_log: event_log
		}
	}

	files := app.admin_state_list_source_files()
	assert files.any(it.language == 'toml' && it.path == current_file)
	assert files.any(it.language == 'typescript' && it.path == plugin_file)

	draft := app.admin_state_open_source_file_draft('../examples/plugin/app.mts')
	assert draft.ok
	assert draft.language == 'typescript'
	assert draft.entry.value.contains('return "old"')

	app.admin_state_put_draft(draft.draft_id, 'export function handler() { return "new"; }\n') or {
		panic(err)
	}
	published := app.admin_state_publish_source_draft(draft.draft_id, '')
	assert published.ok
	assert published.language == 'typescript'
	assert os.read_file(plugin_file) or { panic(err) }.contains('return "new"')
}

fn test_admin_state_source_file_rejects_outside_project() {
	root := admin_state_runtime_test_root('vhttpd_admin_state_source_file_outside')
	defer {
		os.rmdir_all(root) or {}
	}
	admin_dir := os.join_path(root, 'admin')
	os.mkdir_all(admin_dir) or { panic(err) }
	current_file := os.join_path(admin_dir, 'admin.toml')
	event_log := os.join_path(root, 'events.ndjson')
	os.write_file(event_log, '') or { panic(err) }
	os.write_file(current_file, admin_state_named_runtime_plan_text('admin', 18088, 'admin')) or {
		panic(err)
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		DataPlaneRuntime: DataPlaneRuntime{
			plan: current_plan
		}
		control_plane:    ControlPlaneRuntime{
			event_log: event_log
		}
	}

	result := app.admin_state_open_source_file_draft('../../outside.mts')
	assert !result.ok
	assert result.error.contains('admin_source_file_path_outside_project')
}
