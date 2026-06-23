module config

import os

fn test_load_runtime_plan_file_uses_strict_v2_when_version_is_two() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_v2_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[engines.vjsx]
kind = "vjsx"
entry = "app.mts"

[adapters.app]
kind = "http-handler"
engine = "engine:vjsx"

[[pipelines]]
id = "site"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert !plan.source.compatibility
	assert plan.source.config_path == os.abs_path(config_file)
	assert plan.listeners['web'].port == 18080
	assert plan.pipeline('site')?.egress.str() == 'adapter:app'
}

fn test_load_runtime_plan_file_falls_back_to_v1_without_version() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_v1_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[server]
host = "127.0.0.1"
port = 18081

[site]
name = "legacy"
document_root = "/srv/legacy"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert plan.source.compatibility
	assert plan.listeners['default'].port == 18081
	assert plan.adapters['legacy/default'].options.strings['document_root'] == '/srv/legacy'
	assert plan.diagnostics.any(it.code == 'legacy_schema')
}

fn test_load_runtime_plan_file_rejects_unsupported_version() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_bad_version_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, 'version = 99') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	if _ := load_runtime_plan_file(config_file) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_unsupported_version:99'
	}
}

fn test_load_runtime_plan_file_rejects_unknown_v2_root_field() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_unknown_root_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2
surprise = true
') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	if _ := load_runtime_plan_file(config_file) {
		assert false
	} else {
		assert err.msg() == 'v2_config_unknown_field:surprise'
	}
}

fn test_load_runtime_plan_file_rejects_unknown_v2_nested_field() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_unknown_nested_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[engines.app]
kind = "vjsx"
entry = "app.mts"
poolz = 3
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	if _ := load_runtime_plan_file(config_file) {
		assert false
	} else {
		assert err.msg() == 'v2_config_unknown_field:engines.app.poolz'
	}
}

fn test_load_runtime_plan_file_allows_extension_options() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_options_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18082

[engines.app]
kind = "vjsx"
entry = "app.mts"
options = { custom_flag = "ok" }

[adapters.app]
kind = "http-handler"
engine = "engine:app"
options = { custom_adapter_flag = "ok" }

[[pipelines]]
id = "site"
ingress = "listener:web"
match.paths = ["*"]
match.headers = { x_custom = "yes" }
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.engines['app'].options.strings['custom_flag'] == 'ok'
	assert plan.adapters['app'].options.strings['custom_adapter_flag'] == 'ok'
	assert plan.pipelines[0].match.headers['x_custom'] == 'yes'
}
