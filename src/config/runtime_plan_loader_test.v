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

fn test_load_runtime_plan_file_accepts_hello_v2_example() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..', '..'))
	config_file := os.join_path(repo_root, 'examples', 'config', 'hello-v2.toml')
	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert !plan.source.compatibility
	assert plan.listeners['web'].port == 19882
	assert plan.engines['hello'].kind == 'vjsx'
	assert plan.adapters['hello'].engine?.str() == 'engine:hello'
	assert plan.pipelines[0].id == 'hello'
}

fn test_load_runtime_plan_file_accepts_wordpress_v2_example() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..', '..'))
	config_file := os.join_path(repo_root, 'examples', 'wordpress', 'vhttpd-v2.toml')
	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert !plan.source.compatibility
	assert plan.listeners['web'].tls.enabled
	assert plan.resources['db/wordpress'].options.strings['pool_name'] == 'wordpress'
	assert plan.resources['cache/wordpress'].kind == 'session-store'
	assert plan.resources['storage/wordpress'].options.strings['root'] == '/Users/guweigang/wwwroot/wordpress'
	assert plan.engines['php'].kind == 'php-worker'
	assert plan.engines['php'].resources.map(it.str()).contains('resource:db/wordpress')
	assert plan.engines['php-cgi'].kind == 'php-cgi'
	assert plan.adapters['wordpress-worker'].engine?.str() == 'engine:php'
	assert plan.adapters['wordpress-cgi'].engine?.str() == 'engine:php-cgi'
	assert plan.adapters['vhttpd-upload'].options.strings['completed_pipeline'] == 'pipeline:upload.completed'
	assert plan.policies['cache/front-page'].options.ints['ttl_ms'] == 30000
	assert plan.policies['response/wp-json-options'].options.string_maps['headers']['Access-Control-Allow-Methods'] == 'GET, HEAD, OPTIONS'
	assert plan.transforms['wp-json-rewrite'].options.strings['strip_prefix'] == '/wp-json'
	assert plan.pipeline('wordpress.front-page')?.egress.str() == 'adapter:wordpress-worker'
	assert plan.pipeline('rest.pretty-route')?.transforms[0].str() == 'transform:wp-json-rewrite'
	assert plan.pipeline('upload.completed')?.transforms[0].str() == 'transform:upload-completed'
}

fn test_load_runtime_plan_file_resolves_v2_relative_paths_and_env_defaults() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_v2_paths_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	app_file := os.join_path(config_dir, 'app.mts')
	os.write_file(app_file,
		'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[server]
pid_file = "run/vhttpd.pid"

[observability]
event_log = "\${paths.root}/logs/events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18083

[resources.storage.uploads]
kind = "filesystem"
root = "uploads"

[engines.app]
kind = "vjsx"
entry = "\${env.VHTTPD_TEST_V2_ENTRY:-app.mts}"
module_root = "."

[adapters.app]
kind = "http-handler"
engine = "engine:app"
document_root = "public"

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
	assert plan.server.pid_file == os.join_path(config_dir, 'run', 'vhttpd.pid')
	assert plan.observability.event_log == os.join_path(config_dir, 'logs', 'events.ndjson')
	assert plan.resources['storage/uploads'].options.strings['root'] == os.join_path(config_dir,
		'uploads')
	assert plan.engines['app'].options.strings['entry'] == app_file
	assert plan.engines['app'].options.strings['module_root'] == config_dir
	assert plan.adapters['app'].options.strings['document_root'] == os.join_path(config_dir,
		'public')
}
