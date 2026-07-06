module main

import config
import os
import time

fn admin_state_runtime_test_root(name string) string {
	return os.join_path(os.temp_dir(), '${name}_${time.now().unix_micro()}')
}

fn admin_state_runtime_plan_text(body string) string {
	return '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[adapters.hello]
kind = "fixed-response"

[adapters.hello.options]
status = "200"
body = "${body}"

[[pipelines]]
id = "web"
ingress = "listener:web"
egress = "adapter:hello"

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
		control_plane: ControlPlaneRuntime{
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
