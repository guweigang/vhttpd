module main

import json
import os

struct TestShutdownExecutorLifecycle {}

fn (l TestShutdownExecutorLifecycle) name() string {
	_ = l
	return 'test_shutdown_lifecycle'
}

fn (l TestShutdownExecutorLifecycle) prepare_bootstrap(args []string, cfg VhttpdConfig, mut state ExecutorBootstrapState) ! {
	_ = l
	_ = args
	_ = cfg
	_ = state
}

fn (l TestShutdownExecutorLifecycle) start(mut app App) {
	_ = l
	_ = app
}

fn (l TestShutdownExecutorLifecycle) stop(mut app App) {
	_ = l
	app.emit('test.executor.stopped', {
		'source': 'lifecycle'
	})
}

struct TestShutdownProviderRuntime {}

struct TestShutdownProvider {}

fn (p TestShutdownProvider) init(mut app App) ! {
	_ = p
	_ = app
	return
}

fn (p TestShutdownProvider) start(mut app App) ! {
	_ = p
	_ = app
	return
}

fn (p TestShutdownProvider) stop(mut app App) ! {
	_ = p
	_ = app
	return
}

fn (p TestShutdownProvider) snapshot(mut app App) string {
	_ = p
	_ = app
	return '{}'
}

fn (r TestShutdownProviderRuntime) start(mut app App) ! {
	_ = r
	_ = app
	return
}

fn (r TestShutdownProviderRuntime) stop(mut app App) ! {
	_ = r
	app.emit('test.provider.stopped', {
		'source': 'provider'
	})
	return
}

fn (r TestShutdownProviderRuntime) snapshot(mut app App) string {
	_ = r
	_ = app
	return '{}'
}

struct TestShutdownLogicExecutorState {
mut:
	close_called bool
}

struct TestShutdownLogicExecutor {
mut:
	state &TestShutdownLogicExecutorState = unsafe { nil }
}

fn (e TestShutdownLogicExecutor) model() LogicExecutorModel {
	_ = e
	return .embedded
}

fn (e TestShutdownLogicExecutor) kind() string {
	_ = e
	return 'test_shutdown_executor'
}

fn (e TestShutdownLogicExecutor) provider() string {
	_ = e
	return 'test_shutdown_executor'
}

fn (e TestShutdownLogicExecutor) admin_details() LogicExecutorAdminDetails {
	_ = e
	return LogicExecutorAdminDetails{
		kind:     'test_shutdown_executor'
		provider: 'test_shutdown_executor'
		model:    LogicExecutorModel.embedded.str()
	}
}

fn (e TestShutdownLogicExecutor) warmup(mut app App) ! {
	_ = e
	_ = app
}

fn (e TestShutdownLogicExecutor) close() {
	if isnil(e.state) {
		return
	}
	mut state := e.state
	state.close_called = true
}

fn (e TestShutdownLogicExecutor) dispatch_http(mut app App, req HttpLogicDispatchRequest) !HttpLogicDispatchOutcome {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e TestShutdownLogicExecutor) open_websocket_session(mut app App, req WebSocketSessionOpenRequest) !WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e TestShutdownLogicExecutor) dispatch_stream(mut app App, req StreamDispatchRequest) !StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e TestShutdownLogicExecutor) dispatch_mcp(mut app App, req WorkerMcpDispatchRequest) !WorkerMcpDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e TestShutdownLogicExecutor) dispatch_websocket_upstream(mut app App, req WorkerWebSocketUpstreamDispatchRequest) !WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e TestShutdownLogicExecutor) dispatch_websocket_event(mut app App, frame WorkerWebSocketFrame) !WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('not_used')
}

fn test_load_vhttpd_config_parses_executor_and_vjsx_sections() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_executor_config_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[executor]
kind = "vjsx"

[vjsx]
app_entry = "\${env.VHTTPD_VJSX_ENTRY:-/tmp/app.mts}"
module_root = "\${env.VHTTPD_VJSX_ROOT:-/tmp}"
build_root = "\${env.VHTTPD_VJSX_BUILD_ROOT:-/tmp/vjsx-cache}"
runtime_profile = "node"
thread_count = 3
') or {
		panic(err)
	}
	defer {
		os.rm(config_file) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.executor.kind == 'vjsx'
	assert cfg.vjsx.app_entry == '/tmp/app.mts'
	assert cfg.vjsx.module_root == '/tmp'
	assert cfg.vjsx.build_root == '/tmp/vjsx-cache'
	assert cfg.vjsx.runtime_profile == 'node'
	assert cfg.vjsx.thread_count == 3
}

fn test_execute_websocket_dispatch_commands_result_treats_targeted_close_as_hub_command() {
	mut app := App{}
	result := app.execute_websocket_dispatch_commands_result([
		WorkerWebSocketFrame{
			event:     'close'
			id:        'source_conn'
			target_id: 'target_conn'
			code:      1001
			reason:    'Client disconnected'
		},
	])
	assert !result.has_close
	assert result.failures.len == 0
	assert result.close_frame.event == ''
}

fn test_execute_websocket_dispatch_commands_result_keeps_current_socket_close_as_return_close() {
	mut app := App{}
	result := app.execute_websocket_dispatch_commands_result([
		WorkerWebSocketFrame{
			event:  'close'
			id:     'source_conn'
			code:   1000
			reason: 'done'
		},
	])
	assert result.has_close
	assert result.failures.len == 0
	assert result.close_frame.event == 'close'
	assert result.close_frame.id == 'source_conn'
	assert result.close_frame.target_id == ''
}

fn test_load_vhttpd_config_supports_paths_root_and_aliases() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_paths_config_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	expected_root := os.abs_path(temp_dir)
	expected_php_app := os.join_path(expected_root, 'apps', 'hello.php')
	expected_vjsx_app := os.join_path(expected_root, 'apps', 'hello.mts')
	expected_vjsx_root := os.join_path(expected_root, 'apps')
	expected_vjsx_build_root := os.join_path(expected_root, 'build-cache')
	expected_vjsx_sig_root := os.join_path(expected_root, 'sig')
	expected_assets_root := os.join_path(expected_root, 'public')
	expected_socket_prefix := os.join_path(expected_root, 'run', 'worker')
	expected_pid := os.join_path(expected_root, 'tmp', 'vhttpd.pid')
	expected_log := os.join_path(expected_root, 'tmp', 'vhttpd.events.ndjson')
	os.write_file(config_file, '
[paths]
root = ".."
php_app = "apps/hello.php"
vjsx_app = "apps/hello.mts"
vjsx_root = "apps"
vjsx_build_root = "build-cache"
vjsx_sig_root = "sig"
assets_root = "public"
socket_prefix = "run/worker"

[files]
pid_file = "tmp/vhttpd.pid"
event_log = "tmp/vhttpd.events.ndjson"

[worker]
socket_prefix = "\${paths.socket_prefix}"

[worker.env]
VHTTPD_APP = "\${paths.php_app}"

[executor]
kind = "vjsx"

[vjsx]
app_entry = "\${paths.vjsx_app}"
module_root = "\${paths.vjsx_root}"
build_root = "\${paths.vjsx_build_root}"
signature_root = "\${paths.vjsx_sig_root}"
signature_include = ["\${paths.vjsx_root}/**/*.mts"]
runtime_profile = "node"
thread_count = 2

[assets]
root = "\${paths.assets_root}"
') or {
		panic(err)
	}
	defer {
		os.rm(config_file) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.paths.root == expected_root
	assert cfg.paths.values['php_app'] == expected_php_app
	assert cfg.paths.values['vjsx_app'] == expected_vjsx_app
	assert cfg.paths.values['assets_root'] == expected_assets_root
	assert cfg.files.pid_file == expected_pid
	assert cfg.files.event_log == expected_log
	assert cfg.worker.socket_prefix == expected_socket_prefix
	assert cfg.worker.env['VHTTPD_APP'] == expected_php_app
	assert cfg.vjsx.app_entry == expected_vjsx_app
	assert cfg.vjsx.module_root == expected_vjsx_root
	assert cfg.vjsx.build_root == expected_vjsx_build_root
	assert cfg.vjsx.signature_root == expected_vjsx_sig_root
	assert cfg.vjsx.signature_include[0] == 'apps/**/*.mts'
	assert cfg.assets.root == expected_assets_root
}

fn test_resolve_provider_runtime_settings_supports_pgsql_db_config() {
	mut cfg := default_vhttpd_config()
	cfg.db.enabled = true
	cfg.db.driver = 'pgsql'
	cfg.db.socket = '/tmp/vhttpd-db-pg.sock'
	cfg.db.pgsql.host = '127.0.0.1'
	cfg.db.pgsql.port = 5433
	cfg.db.pgsql.username = 'postgres'
	cfg.db.pgsql.password = 'secret'
	cfg.db.pgsql.database = 'appdb'
	cfg.db.pgsql.pool_size = 9
	settings := resolve_provider_runtime_settings([]string{}, cfg)
	assert settings.db.enabled
	assert settings.db.driver == 'pgsql'
	assert settings.db.socket == '/tmp/vhttpd-db-pg.sock'
	assert settings.db.host == '127.0.0.1'
	assert settings.db.port == 5433
	assert settings.db.username == 'postgres'
	assert settings.db.password == 'secret'
	assert settings.db.database == 'appdb'
	assert settings.db.pool_size == 9
}

fn test_load_vhttpd_config_supports_bridge_config() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_bridge_toml_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[feishu.bridge]
enabled = true
ws_url = "wss://bridge.example/ws"
client_id = "local-main"
token = "bridge-secret"
target_id = "remote-main"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.feishu.bridge.enabled
	assert cfg.feishu.bridge.ws_url == 'wss://bridge.example/ws'
	assert cfg.feishu.bridge.client_id == 'local-main'
	assert cfg.feishu.bridge.token == 'bridge-secret'
	assert cfg.feishu.bridge.target_id == 'remote-main'
}

fn test_resolve_provider_runtime_settings_supports_bridge_config() {
	mut cfg := default_vhttpd_config()
	cfg.feishu.bridge.enabled = true
	cfg.feishu.bridge.ws_url = 'wss://bridge.example/ws'
	cfg.feishu.bridge.client_id = 'local-main'
	cfg.feishu.bridge.token = 'bridge-secret'
	cfg.feishu.bridge.target_id = 'remote-main'
	settings := resolve_provider_runtime_settings([]string{}, cfg)
	assert settings.bridge.enabled
	assert settings.bridge.ws_url == 'wss://bridge.example/ws'
	assert settings.bridge.client_id == 'local-main'
	assert settings.bridge.token == 'bridge-secret'
	assert settings.bridge.target_id == 'remote-main'
}

fn test_load_vhttpd_config_supports_multi_listener_sites() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_multi_listener_toml_test')
	config_dir := os.join_path(temp_dir, 'config')
	project_a_dir := os.join_path(temp_dir, 'project-a')
	project_b_dir := os.join_path(temp_dir, 'project-b')
	os.mkdir_all(config_dir) or { panic(err) }
	os.mkdir_all(project_a_dir) or { panic(err) }
	os.mkdir_all(project_b_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	php_worker := os.join_path(project_a_dir, 'php-worker.php')
	php_app := os.join_path(project_a_dir, 'app.php')
	vjsx_app := os.join_path(project_b_dir, 'app.mts')
	os.write_file(php_worker, '<?php echo "worker";') or { panic(err) }
	os.write_file(php_app, '<?php echo "app";') or { panic(err) }
	os.write_file(vjsx_app, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	os.write_file(config_file, '
[paths]
root = ".."
project_a_root = "project-a"
project_b_root = "project-b"
project_a_php_worker = "\${paths.project_a_root}/php-worker.php"
project_a_php_app = "\${paths.project_a_root}/app.php"
project_b_vjsx_app = "\${paths.project_b_root}/app.mts"

[files]
pid_file = "run/vhttpd.pid"
event_log = "logs/vhttpd.events.ndjson"

[assets]
enabled = true
prefix = "/assets"
root = "public"

[codex]
enabled = true
model = "gpt-5.4"

[listeners.project_a]
host = "127.0.0.1"
port = 18081
site = "project_a"

[listeners.project_b]
host = "127.0.0.1"
port = 18082
site = "project_b"

[sites.project_a]
project_root = "\${paths.project_a_root}"
executor = "php"
php.worker_entry = "\${paths.project_a_php_worker}"
php.app_entry = "\${paths.project_a_php_app}"

[sites.project_b]
project_root = "\${paths.project_b_root}"
executor = "vjsx"
vjsx.app_entry = "\${paths.project_b_vjsx_app}"
vjsx.module_root = "\${paths.project_b_root}"
vjsx.runtime_profile = "node"
vjsx.thread_count = 2
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.listeners.len == 2
	assert cfg.sites.len == 2
	assert cfg.listeners['project_a'].site == 'project_a'
	assert cfg.listeners['project_b'].port == 18082
	assert cfg.assets.enabled
	assert cfg.assets.root == os.join_path(temp_dir, 'public')
	assert cfg.codex.enabled
	assert cfg.codex.model == 'gpt-5.4'
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert multi_cfg.listeners.len == 2
	assert multi_cfg.listeners[0].site_cfg.paths.root == project_a_dir
	assert multi_cfg.listeners[0].site_cfg.php.worker_entry == php_worker
	assert multi_cfg.listeners[0].site_cfg.php.app_entry == php_app
	assert multi_cfg.listeners[1].site_cfg.vjsx.app_entry == vjsx_app
	assert multi_cfg.listeners[1].site_cfg.vjsx.module_root == project_b_dir
}

fn test_load_vhttpd_config_supports_site_executor_shorthand() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_executor_shorthand_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[listeners.demo]
host = "127.0.0.1"
port = 19881
site = "demo"

[sites.demo]
project_root = "."
executor = "vjsx"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.sites['demo'].executor.kind == 'vjsx'
}

fn test_load_vhttpd_config_supports_site_host_port_shorthand() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_host_port_shorthand_test')
	config_dir := os.join_path(temp_dir, 'config')
	project_dir := os.join_path(temp_dir, 'project')
	os.mkdir_all(config_dir) or { panic(err) }
	os.mkdir_all(project_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	app_file := os.join_path(project_dir, 'app.mts')
	os.write_file(app_file, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	os.write_file(config_file, '
[paths]
root = ".."
project_root = "project"
app_entry = "project/app.mts"

[sites.demo]
host = "127.0.0.1"
port = 19883
root = "\${paths.project_root}"
executor = "vjsx"
app = "\${paths.app_entry}"
vjsx.runtime_profile = "node"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.listeners.len == 0
	assert cfg.sites['demo'].host == '127.0.0.1'
	assert cfg.sites['demo'].port == 19883
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert multi_cfg.listeners.len == 1
	assert multi_cfg.listeners[0].id == 'demo'
	assert multi_cfg.listeners[0].site_id == 'demo'
	assert multi_cfg.listeners[0].runtime_cfg.host == '127.0.0.1'
	assert multi_cfg.listeners[0].runtime_cfg.port == 19883
	assert multi_cfg.listeners[0].runtime_cfg.executor_plan.executor.kind() == 'vjsx'
	assert multi_cfg.listeners[0].site_cfg.vjsx.app_entry == app_file
	assert multi_cfg.listeners[0].site_cfg.vjsx.module_root == project_dir
}

fn test_load_vhttpd_config_supports_site_root_alias() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_root_alias_test')
	config_dir := os.join_path(temp_dir, 'config')
	project_dir := os.join_path(temp_dir, 'project')
	os.mkdir_all(config_dir) or { panic(err) }
	os.mkdir_all(project_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	app_file := os.join_path(project_dir, 'app.mts')
	os.write_file(app_file, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	os.write_file(config_file, '
[paths]
root = ".."
site_root = "project"
site_app = "project/app.mts"

[sites.demo]
host = "127.0.0.1"
port = 19884
root = "\${paths.site_root}"
executor = "vjsx"
app = "\${paths.site_app}"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.sites['demo'].project_root == '\${paths.site_root}'
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert multi_cfg.listeners.len == 1
	assert multi_cfg.listeners[0].site_cfg.paths.root == project_dir
	assert multi_cfg.listeners[0].site_cfg.vjsx.app_entry == app_file
}

fn test_resolve_multi_server_runtime_config_keeps_global_path_aliases_stable_when_site_root_is_set() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_root_global_paths_stable_test')
	config_dir := os.join_path(temp_dir, 'config')
	project_dir := os.join_path(temp_dir, 'project')
	build_dir := os.join_path(temp_dir, 'tmp', 'vjsx-build')
	os.mkdir_all(config_dir) or { panic(err) }
	os.mkdir_all(project_dir) or { panic(err) }
	os.mkdir_all(build_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	app_file := os.join_path(project_dir, 'app.mts')
	os.write_file(app_file, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	os.write_file(config_file, '
[paths]
root = ".."
vjsx_app = "project/app.mts"
vjsx_build_root = "tmp/vjsx-build"

[sites.demo]
host = "127.0.0.1"
port = 19885
root = "project"
executor = "vjsx"
app = "\${paths.vjsx_app}"
vjsx.build_root = "\${paths.vjsx_build_root}"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert multi_cfg.listeners.len == 1
	assert multi_cfg.listeners[0].site_cfg.paths.root == project_dir
	assert multi_cfg.listeners[0].site_cfg.vjsx.app_entry == app_file
	assert multi_cfg.listeners[0].site_cfg.vjsx.module_root == project_dir
	assert multi_cfg.listeners[0].site_cfg.vjsx.build_root == build_dir
}

fn test_resolve_multi_server_runtime_config_does_not_double_prefix_site_root_for_global_app_alias() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_root_double_prefix_test')
	config_dir := os.join_path(temp_dir, 'config')
	project_dir := os.join_path(temp_dir, 'examples', 'paseo-relay')
	build_dir := os.join_path(temp_dir, 'tmp', 'paseo-relay-vjsx-build')
	os.mkdir_all(config_dir) or { panic(err) }
	os.mkdir_all(project_dir) or { panic(err) }
	os.mkdir_all(build_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	app_file := os.join_path(project_dir, 'app.mts')
	os.write_file(app_file, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	os.write_file(config_file, '
[paths]
root = ".."
vjsx_app = "examples/paseo-relay/app.mts"
vjsx_build_root = "tmp/paseo-relay-vjsx-build"

[sites.paseo_relay]
host = "127.0.0.1"
port = 19901
root = "examples/paseo-relay"
executor = "vjsx"
app = "\${paths.vjsx_app}"
vjsx.build_root = "\${paths.vjsx_build_root}"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert multi_cfg.listeners.len == 1
	assert multi_cfg.listeners[0].site_cfg.paths.root == project_dir
	assert multi_cfg.listeners[0].site_cfg.vjsx.app_entry == app_file
	assert multi_cfg.listeners[0].site_cfg.vjsx.module_root == project_dir
	assert multi_cfg.listeners[0].site_cfg.vjsx.build_root == build_dir
}

fn test_site_config_as_vhttpd_config_defaults_vjsx_module_root_to_site_root() {
	cfg := site_config_as_vhttpd_config(default_vhttpd_config(), SiteConfig{
		project_root: '/tmp/site-root'
		executor:     ExecutorConfig{
			kind: 'vjsx'
		}
		vjsx:         VjsxConfig{
			app_entry: './app.mts'
		}
	})
	assert cfg.paths.root == '/tmp/site-root'
	assert cfg.vjsx.module_root == '/tmp/site-root'
}

fn test_site_config_as_vhttpd_config_routes_app_alias_to_vjsx() {
	cfg := site_config_as_vhttpd_config(default_vhttpd_config(), SiteConfig{
		project_root: '/tmp/site-root'
		executor:     ExecutorConfig{
			kind: 'vjsx'
		}
		app:          './app.mts'
	})
	assert cfg.vjsx.app_entry == './app.mts'
	assert cfg.php.app_entry == ''
}

fn test_site_config_as_vhttpd_config_routes_app_alias_to_php() {
	cfg := site_config_as_vhttpd_config(default_vhttpd_config(), SiteConfig{
		project_root: '/tmp/site-root'
		executor:     ExecutorConfig{
			kind: 'php'
		}
		app:          './app.php'
	})
	assert cfg.php.app_entry == './app.php'
	assert cfg.vjsx.app_entry == ''
}

fn test_site_config_as_vhttpd_config_routes_worker_entry_alias_to_php() {
	cfg := site_config_as_vhttpd_config(default_vhttpd_config(), SiteConfig{
		project_root: '/tmp/site-root'
		executor:     ExecutorConfig{
			kind: 'php'
		}
		worker_entry: './php-worker'
	})
	assert cfg.php.worker_entry == './php-worker'
}

fn test_site_config_as_vhttpd_config_infers_executor_from_app_alias() {
	php_cfg := site_config_as_vhttpd_config(default_vhttpd_config(), SiteConfig{
		project_root: '/tmp/site-root'
		app:          './app.php'
	})
	assert php_cfg.executor.kind == 'php'
	assert php_cfg.php.app_entry == './app.php'
	vjsx_cfg := site_config_as_vhttpd_config(default_vhttpd_config(), SiteConfig{
		project_root: '/tmp/site-root'
		app:          './app.mts'
	})
	assert vjsx_cfg.executor.kind == 'vjsx'
	assert vjsx_cfg.vjsx.app_entry == './app.mts'
}

fn test_load_vhttpd_config_supports_merged_site_worker_and_php_tables() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_merged_tables_test')
	config_dir := os.join_path(temp_dir, 'config')
	php_worker_dir := os.join_path(temp_dir, 'config', 'php', 'package', 'bin')
	examples_dir := os.join_path(temp_dir, 'config', 'examples')
	os.mkdir_all(config_dir) or { panic(err) }
	os.mkdir_all(php_worker_dir) or { panic(err) }
	os.mkdir_all(examples_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	php_worker := os.join_path(php_worker_dir, 'php-worker')
	php_app := os.join_path(examples_dir, 'hello-app.php')
	os.write_file(php_worker, '#!/usr/bin/env php') or { panic(err) }
	os.write_file(php_app, '<?php echo "hello";') or { panic(err) }
	os.write_file(config_file, '
[listeners.demo]
host = "127.0.0.1"
port = 19881
site = "demo"

[sites.demo]
project_root = "."
executor = "php"
worker.entry = "php/package/bin/php-worker"
worker.autostart = true
worker.pool_size = 2
worker.socket_prefix = "tmp/demo-worker"
php.bin = "php"
app = "examples/hello-app.php"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.sites['demo'].executor.kind == 'php'
	assert cfg.sites['demo'].worker.autostart
	assert cfg.sites['demo'].worker.pool_size == 2
	assert cfg.sites['demo'].worker.socket_prefix == 'tmp/demo-worker'
	assert cfg.sites['demo'].php.bin == 'php'
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert multi_cfg.listeners.len == 1
	assert multi_cfg.listeners[0].site_cfg.worker.socket_prefix == os.join_path(config_dir,
		'tmp', 'demo-worker')
	assert multi_cfg.listeners[0].site_cfg.php.worker_entry == php_worker
	assert multi_cfg.listeners[0].site_cfg.php.app_entry == php_app
}

fn test_load_vhttpd_config_parses_php_section_and_resolves_paths() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_php_config_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	expected_root := os.abs_path(temp_dir)
	expected_worker_entry := os.join_path(expected_root, 'php', 'package', 'bin', 'php-worker')
	expected_app_entry := os.join_path(expected_root, 'apps', 'hello.php')
	expected_ext_a := os.join_path(expected_root, 'ext', 'a.so')
	expected_ext_b := '/tmp/custom-b.so'
	os.write_file(config_file, '
[paths]
root = ".."
php_worker = "php/package/bin/php-worker"
php_app = "apps/hello.php"
ext_a = "ext/a.so"

[executor]
kind = "php"

[php]
bin = "php"
worker_entry = "\${paths.php_worker}"
app_entry = "\${paths.php_app}"
extensions = ["\${paths.ext_a}", "/tmp/custom-b.so"]
args = ["-d", "memory_limit=512M"]
') or {
		panic(err)
	}
	defer {
		os.rm(config_file) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.paths.root == expected_root
	assert cfg.php.bin == 'php'
	assert cfg.php.worker_entry == expected_worker_entry
	assert cfg.php.app_entry == expected_app_entry
	assert cfg.php.extensions.len == 2
	assert cfg.php.extensions[0] == expected_ext_a
	assert cfg.php.extensions[1] == expected_ext_b
	assert cfg.php.args.len == 2
	assert cfg.php.args[0] == '-d'
	assert cfg.php.args[1] == 'memory_limit=512M'
}

fn test_load_vhttpd_config_expands_same_section_paths_short_reference() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_paths_same_section_short_reference_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	expected_root := os.abs_path(temp_dir)
	expected_app := os.join_path(expected_root, 'examples', 'paseo-relay', 'app.mts')
	expected_build_root := os.join_path(expected_root, 'tmp', 'paseo-relay-vjsx-build')
	os.write_file(config_file, '
[paths]
root = ".."
vjsx_app = "\${root}/examples/paseo-relay/app.mts"
vjsx_build_root = "\${root}/tmp/paseo-relay-vjsx-build"

[executor]
kind = "vjsx"

[vjsx]
app_entry = "\${paths.vjsx_app}"
build_root = "\${paths.vjsx_build_root}"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.paths.root == expected_root
	assert cfg.paths.values['vjsx_app'] == expected_app
	assert cfg.paths.values['vjsx_build_root'] == expected_build_root
	assert cfg.vjsx.app_entry == expected_app
	assert cfg.vjsx.build_root == expected_build_root
}

fn test_load_vhttpd_config_prefers_same_section_variable_over_global_fallback() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_same_section_precedence_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	expected_root := '/assets-prefix'
	os.write_file(config_file, '
[assets]
prefix = "/assets-prefix"
root = "\${prefix}"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.assets.prefix == expected_root
	assert cfg.assets.root == expected_root
}

fn test_load_vhttpd_config_keeps_absolute_paths_outside_paths_root() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_paths_absolute_config_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	expected_root := os.abs_path(temp_dir)
	expected_php_app := '/tmp/vhttpd_absolute_php_app.php'
	expected_socket_prefix := '/tmp/vhttpd_absolute_worker'
	os.write_file(config_file, '
[paths]
root = ".."
php_app = "/tmp/vhttpd_absolute_php_app.php"
socket_prefix = "/tmp/vhttpd_absolute_worker"

[worker]
socket_prefix = "\${paths.socket_prefix}"

[worker.env]
VHTTPD_APP = "\${paths.php_app}"
') or {
		panic(err)
	}
	defer {
		os.rm(config_file) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.paths.root == expected_root
	assert cfg.paths.values['php_app'] == expected_php_app
	assert cfg.paths.values['socket_prefix'] == expected_socket_prefix
	assert cfg.worker.socket_prefix == expected_socket_prefix
	assert cfg.worker.env['VHTTPD_APP'] == expected_php_app
}

fn test_load_vhttpd_config_normalizes_trailing_slashes_in_paths_aliases() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_paths_trailing_slash_config_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	expected_root := os.abs_path(temp_dir)
	expected_assets_root := os.join_path(expected_root, 'public')
	expected_vjsx_root := os.join_path(expected_root, 'apps')
	expected_socket_prefix := os.join_path(expected_root, 'run', 'worker')
	os.write_file(config_file, '
[paths]
root = "../"
assets_root = "public/"
vjsx_root = "apps/"
socket_prefix = "run/worker/"

[worker]
socket_prefix = "\${paths.socket_prefix}"

[executor]
kind = "vjsx"

[vjsx]
app_entry = "examples/vjsx/hello-handler.mts"
module_root = "\${paths.vjsx_root}"

[assets]
root = "\${paths.assets_root}"
') or {
		panic(err)
	}
	defer {
		os.rm(config_file) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.paths.root == expected_root
	assert cfg.paths.values['assets_root'] == expected_assets_root
	assert cfg.paths.values['vjsx_root'] == expected_vjsx_root
	assert cfg.paths.values['socket_prefix'] == expected_socket_prefix
	assert cfg.worker.socket_prefix == expected_socket_prefix
	assert cfg.vjsx.module_root == expected_vjsx_root
	assert cfg.assets.root == expected_assets_root
}

fn test_resolve_executor_runtime_defaults_to_disabled_executor() {
	selection := resolve_executor_runtime([]string{}, default_vhttpd_config()) or { panic(err) }
	assert selection.lifecycle.name() == 'disabled'
	assert selection.executor.model() == .worker
	assert selection.executor.kind() == 'none'
	assert selection.executor.provider() == 'none'
	assert selection.worker_backend_mode == .disabled
}

fn test_build_php_worker_command_from_php_section() {
	php_cfg := PhpConfig{
		bin:          'php'
		worker_entry: '/tmp/php-worker'
		extensions:   ['/tmp/a.so', '/tmp/b.so']
		args:         ['-d', 'memory_limit=512M']
	}
	cmd := build_php_worker_command(php_cfg) or { panic(err) }
	assert cmd == "'php' '-d' 'extension=/tmp/a.so' '-d' 'extension=/tmp/b.so' '-d' 'memory_limit=512M' '/tmp/php-worker'"
}

fn test_build_php_worker_command_requires_worker_entry() {
	php_cfg := PhpConfig{
		bin: 'php'
	}
	build_php_worker_command(php_cfg) or {
		assert err.msg() == 'php_worker_entry_missing'
		return
	}
	assert false
}

fn test_build_php_worker_env_prefers_php_app_entry() {
	worker_env := {
		'APP_ENV':    'dev'
		'VHTTPD_APP': '/tmp/from-env.php'
	}
	php_cfg := PhpConfig{
		app_entry: '/tmp/from-php.php'
	}
	env := build_php_worker_env(worker_env, php_cfg)
	assert env['APP_ENV'] == 'dev'
	assert env['VHTTPD_APP'] == '/tmp/from-php.php'
}

fn test_builtin_logic_executor_spec_resolves_php_runtime_config_overrides_from_cli() {
	mut cfg := default_vhttpd_config()
	cfg.php.bin = 'php'
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_php_cli_override_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	worker_entry := os.join_path(temp_dir, 'php-worker')
	app_entry := os.join_path(temp_dir, 'app.php')
	ext_a := os.join_path(temp_dir, 'a.so')
	ext_b := os.join_path(temp_dir, 'b.so')
	os.write_file(worker_entry, '#!/bin/sh') or { panic(err) }
	os.write_file(app_entry, '<?php return [];') or { panic(err) }
	os.write_file(ext_a, '') or { panic(err) }
	os.write_file(ext_b, '') or { panic(err) }
	defer {
		os.rm(worker_entry) or {}
		os.rm(app_entry) or {}
		os.rm(ext_a) or {}
		os.rm(ext_b) or {}
	}
	cfg.php.worker_entry = worker_entry
	cfg.php.app_entry = app_entry
	cfg.php.extensions = [ext_a]
	php_spec := builtin_logic_executor_spec('php') or { panic(err) }
	php_cfg := php_spec.resolve_php_runtime_config(['--php-bin', 'php82', '--php-worker-entry',
		worker_entry, '--php-app-entry', app_entry, '--php-extension', ext_a, '--php-extension',
		ext_b, '--php-arg', '-d', '--php-arg', 'memory_limit=512M'], cfg) or { panic(err) }
	assert php_cfg.bin == 'php82'
	assert php_cfg.worker_entry == worker_entry
	assert php_cfg.app_entry == app_entry
	assert php_cfg.extensions.len == 2
	assert php_cfg.extensions[0] == ext_a
	assert php_cfg.extensions[1] == ext_b
	assert php_cfg.args.len == 2
	assert php_cfg.args[0] == '-d'
	assert php_cfg.args[1] == 'memory_limit=512M'
}

fn test_arg_string_list_or_supports_repeated_and_csv_values() {
	values := arg_string_list_or(['--php-extension', '/tmp/a.so',
		'--php-extension=/tmp/b.so,/tmp/c.so'], '--php-extension', [])
	assert values.len == 3
	assert values[0] == '/tmp/a.so'
	assert values[1] == '/tmp/b.so'
	assert values[2] == '/tmp/c.so'
}

fn test_builtin_logic_executor_spec_resolve_php_runtime_config_reports_missing_paths() {
	mut cfg := default_vhttpd_config()
	cfg.php.bin = 'php'
	cfg.php.worker_entry = '/tmp/definitely-missing-worker'
	php_spec := builtin_logic_executor_spec('php') or { panic(err) }
	php_spec.resolve_php_runtime_config([]string{}, cfg) or {
		assert err.msg() == 'php_worker_entry_not_found:/tmp/definitely-missing-worker'
		return
	}
	assert false
}

fn test_resolve_executor_runtime_builds_vjsx_executor() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_executor_runtime_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => ctx.text("ok");') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	selection := resolve_executor_runtime(['--executor', 'vjsx', '--vjsx-entry', app_file,
		'--vjsx-thread-count', '2', '--vjsx-runtime-profile', 'script'], default_vhttpd_config()) or {
		panic(err)
	}
	assert selection.lifecycle.name() == 'embedded_host'
	assert selection.executor.model() == .embedded
	assert selection.executor.kind() == 'vjsx'
	assert selection.executor.provider() == 'vjsx'
	assert selection.worker_backend_mode == .disabled
}

fn test_normalize_executor_kind_accepts_aliases() {
	assert normalize_executor_kind('none') or { panic(err) } == 'none'
	assert normalize_executor_kind('disabled') or { panic(err) } == 'none'
	assert normalize_executor_kind('noop') or { panic(err) } == 'none'
	assert normalize_executor_kind('php-worker') or { panic(err) } == 'php'
	assert normalize_executor_kind('php_worker') or { panic(err) } == 'php'
	assert normalize_executor_kind('vjsx') or { panic(err) } == 'vjsx'
}

fn test_builtin_logic_executor_spec_exposes_runtime_models() {
	none_spec := builtin_logic_executor_spec('none') or { panic(err) }
	assert none_spec.matches_kind('none')
	assert none_spec.matches_kind('disabled')
	assert none_spec.provider == 'none'
	assert none_spec.logic_model == .worker
	assert none_spec.worker_backend_mode == .disabled
	assert none_spec.lifecycle.name() == 'disabled'
	assert none_spec.config_surface.section == 'none'
	php_spec := builtin_logic_executor_spec('php') or { panic(err) }
	assert php_spec.matches_kind('php-worker')
	assert php_spec.provider == 'php-worker'
	assert php_spec.logic_model == .worker
	assert php_spec.worker_backend_mode == .required
	assert php_spec.lifecycle.name() == 'php_worker_host'
	assert php_spec.config_surface.section == 'php'
	assert php_spec.config_surface.app_entry_flag == '--php-app-entry'
	assert php_spec.config_surface.worker_entry_flag == '--php-worker-entry'
	vjsx_spec := builtin_logic_executor_spec('vjsx') or { panic(err) }
	assert vjsx_spec.matches_kind('vjsx')
	assert vjsx_spec.provider == 'vjsx'
	assert vjsx_spec.logic_model == .embedded
	assert vjsx_spec.worker_backend_mode == .disabled
	assert vjsx_spec.lifecycle.name() == 'embedded_host'
	assert vjsx_spec.config_surface.section == 'vjsx'
	assert vjsx_spec.config_surface.app_entry_flag == '--vjsx-entry'
	assert vjsx_spec.config_surface.module_root_flag == '--vjsx-module-root'
	assert vjsx_spec.config_surface.build_root_flag == '--vjsx-build-root'
	assert vjsx_spec.config_surface.lane_count_flag == '--vjsx-thread-count'
	vjsx_snapshot := vjsx_spec.admin_snapshot()
	assert vjsx_snapshot.kind == 'vjsx'
	assert vjsx_snapshot.logic_provider == 'vjsx'
	assert vjsx_snapshot.logic_executor_lifecycle == 'embedded_host'
	assert vjsx_snapshot.config_surface.section == 'vjsx'
}

fn test_admin_logic_executor_specs_snapshot_lists_builtin_executors() {
	mut app := App{}
	snapshot := app.admin_logic_executor_specs_snapshot()
	assert snapshot.len == 3
	assert snapshot[0].kind == 'none'
	assert snapshot[0].logic_provider == 'none'
	assert snapshot[0].logic_executor_lifecycle == 'disabled'
	assert snapshot[0].logic_executor_model == 'worker'
	assert snapshot[0].worker_backend_mode == 'disabled'
	assert snapshot[0].config_surface.section == 'none'
	assert 'disabled' in snapshot[0].aliases
	assert snapshot[1].kind == 'php'
	assert snapshot[1].logic_provider == 'php-worker'
	assert snapshot[1].logic_executor_lifecycle == 'php_worker_host'
	assert snapshot[1].logic_executor_model == 'worker'
	assert snapshot[1].worker_backend_mode == 'required'
	assert snapshot[1].config_surface.section == 'php'
	assert snapshot[1].config_surface.worker_entry_flag == '--php-worker-entry'
	assert 'php-worker' in snapshot[1].aliases
	assert snapshot[2].kind == 'vjsx'
	assert snapshot[2].logic_provider == 'vjsx'
	assert snapshot[2].logic_executor_lifecycle == 'embedded_host'
	assert snapshot[2].logic_executor_model == 'embedded'
	assert snapshot[2].worker_backend_mode == 'disabled'
	assert snapshot[2].config_surface.section == 'vjsx'
	assert snapshot[2].config_surface.app_entry_flag == '--vjsx-entry'
	assert snapshot[2].config_surface.build_root_flag == '--vjsx-build-root'
	assert snapshot[2].config_surface.signature_root_flag == '--vjsx-signature-root'
}

fn test_internal_admin_executors_returns_builtin_executor_specs() {
	mut app := App{}
	resp := app.internal_admin_dispatch(InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/executors'
	})
	assert resp.status == 200
	snapshot := json.decode([]AdminLogicExecutorSpecSnapshot, resp.body) or { panic(err) }
	assert snapshot.len == 3
	assert snapshot[0].kind == 'none'
	assert snapshot[0].logic_provider == 'none'
	assert snapshot[0].logic_executor_lifecycle == 'disabled'
	assert snapshot[0].config_surface.section == 'none'
	assert snapshot[1].kind == 'php'
	assert snapshot[1].logic_provider == 'php-worker'
	assert snapshot[1].logic_executor_lifecycle == 'php_worker_host'
	assert snapshot[1].config_surface.section == 'php'
	assert snapshot[2].kind == 'vjsx'
	assert snapshot[2].logic_provider == 'vjsx'
	assert snapshot[2].logic_executor_lifecycle == 'embedded_host'
	assert snapshot[2].config_surface.section == 'vjsx'
}

fn test_php_worker_executor_lifecycle_prepares_worker_command_and_env() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_php_executor_lifecycle_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	worker_entry := os.join_path(temp_dir, 'php-worker.php')
	app_entry := os.join_path(temp_dir, 'app.php')
	os.write_file(worker_entry, '<?php echo "worker";') or { panic(err) }
	os.write_file(app_entry, '<?php echo "app";') or { panic(err) }
	defer {
		os.rm(worker_entry) or {}
		os.rm(app_entry) or {}
	}
	mut cfg := default_vhttpd_config()
	cfg.php.worker_entry = worker_entry
	cfg.php.app_entry = app_entry
	mut state := ExecutorBootstrapState{
		worker_autostart: true
		worker_env:       {
			'APP_ENV': 'test'
		}
	}
	PhpWorkerExecutorLifecycle{}.prepare_bootstrap([]string{}, cfg, mut state) or { panic(err) }
	assert state.worker_env['APP_ENV'] == 'test'
	assert state.worker_env['VHTTPD_APP'] == app_entry
	assert state.worker_cmd.contains(worker_entry)
}

fn test_embedded_executor_lifecycle_disables_worker_backend_features() {
	mut state := ExecutorBootstrapState{
		worker_sockets:          ['/tmp/a.sock']
		stream_dispatch:         true
		websocket_dispatch_mode: true
		worker_autostart:        true
		worker_cmd:              'php worker.php'
		worker_env:              {
			'VHTTPD_APP': '/tmp/app.php'
		}
	}
	EmbeddedExecutorLifecycle{}.prepare_bootstrap([]string{}, default_vhttpd_config(), mut
		state) or { panic(err) }
	assert state.worker_sockets.len == 0
	assert !state.stream_dispatch
	assert state.websocket_dispatch_mode
	assert !state.worker_autostart
	assert state.worker_cmd == ''
	assert state.worker_env['VHTTPD_APP'] == '/tmp/app.php'
}

fn test_resolve_logic_executor_runtime_plan_defaults_to_php_worker_host() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_executor_runtime_plan_php_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	worker_entry := os.join_path(temp_dir, 'php-worker.php')
	app_entry := os.join_path(temp_dir, 'app.php')
	os.write_file(worker_entry, '<?php echo "worker";') or { panic(err) }
	os.write_file(app_entry, '<?php echo "app";') or { panic(err) }
	defer {
		os.rm(worker_entry) or {}
		os.rm(app_entry) or {}
	}
	mut cfg := default_vhttpd_config()
	cfg.php.worker_entry = worker_entry
	cfg.php.app_entry = app_entry
	plan := resolve_logic_executor_runtime_plan([]string{}, cfg, [
		'/tmp/a.sock',
	], true, true, true, '', {
		'APP_ENV': 'dev'
	}) or { panic(err) }
	assert plan.executor.kind() == 'php'
	assert plan.lifecycle.name() == 'php_worker_host'
	assert plan.worker_backend_mode == .required
	assert plan.bootstrap.worker_sockets == ['/tmp/a.sock']
	assert plan.bootstrap.stream_dispatch
	assert plan.bootstrap.websocket_dispatch_mode
	assert plan.bootstrap.worker_autostart
	assert plan.bootstrap.worker_env['APP_ENV'] == 'dev'
	assert plan.bootstrap.worker_env['VHTTPD_APP'] == app_entry
	assert plan.bootstrap.worker_cmd.contains(worker_entry)
}

fn test_resolve_logic_executor_runtime_plan_defaults_to_disabled_executor() {
	plan := resolve_logic_executor_runtime_plan([]string{}, default_vhttpd_config(), [
		'/tmp/a.sock',
	], true, true, true, 'php worker.php', {
		'APP_ENV': 'dev'
	}) or { panic(err) }
	assert plan.executor.kind() == 'none'
	assert plan.lifecycle.name() == 'disabled'
	assert plan.worker_backend_mode == .disabled
	assert plan.bootstrap.worker_sockets.len == 0
	assert !plan.bootstrap.stream_dispatch
	assert !plan.bootstrap.websocket_dispatch_mode
	assert !plan.bootstrap.worker_autostart
	assert plan.bootstrap.worker_cmd == ''
	assert plan.bootstrap.worker_env['APP_ENV'] == 'dev'
}

fn test_resolve_logic_executor_runtime_plan_for_vjsx_disables_worker_bootstrap() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_executor_runtime_plan_vjsx_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	os.write_file(app_file, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	plan := resolve_logic_executor_runtime_plan(['--executor', 'vjsx', '--vjsx-entry', app_file],
		default_vhttpd_config(), ['/tmp/a.sock'], true, true, true, 'php worker.php',
		{
		'VHTTPD_APP': '/tmp/app.php'
	}) or { panic(err) }
	assert plan.executor.kind() == 'vjsx'
	assert plan.lifecycle.name() == 'embedded_host'
	assert plan.worker_backend_mode == .disabled
	assert plan.bootstrap.worker_sockets.len == 0
	assert !plan.bootstrap.stream_dispatch
	assert plan.bootstrap.websocket_dispatch_mode
	assert !plan.bootstrap.worker_autostart
	assert plan.bootstrap.worker_cmd == ''
	assert plan.bootstrap.worker_env['VHTTPD_APP'] == '/tmp/app.php'
}

fn test_builtin_logic_executor_spec_runtime_selection_builds_vjsx_executor() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_executor_spec_selection_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	os.write_file(app_file, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	spec := builtin_logic_executor_spec('vjsx') or { panic(err) }
	selection := spec.runtime_selection(['--vjsx-entry', app_file], default_vhttpd_config()) or {
		panic(err)
	}
	assert selection.executor.kind() == 'vjsx'
	assert selection.executor.model() == .embedded
	assert selection.worker_backend_mode == .disabled
	assert selection.lifecycle.name() == 'embedded_host'
}

fn test_builtin_logic_executor_spec_resolves_vjsx_runtime_config_from_config_surface() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_executor_spec_vjsx_config_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.mts')
	os.write_file(app_file, 'export default {};') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	vjsx_spec := builtin_logic_executor_spec('vjsx') or { panic(err) }
	vjsx_cfg := vjsx_spec.resolve_vjsx_runtime_config(['--vjsx-entry', app_file, '--vjsx-build-root',
		os.join_path(temp_dir, 'lane-cache'), '--vjsx-thread-count', '2', '--vjsx-runtime-profile',
		'node'], default_vhttpd_config()) or { panic(err) }
	assert vjsx_cfg.app_entry == app_file
	assert vjsx_cfg.thread_count == 2
	assert vjsx_cfg.runtime_profile == 'node'
	assert vjsx_cfg.module_root == temp_dir
	assert vjsx_cfg.build_root == os.join_path(temp_dir, 'lane-cache')
	assert vjsx_cfg.signature_root == temp_dir
}

fn test_build_app_runtime_projects_executor_plan_into_app_state() {
	mut cfg := default_vhttpd_config()
	cfg.mcp.max_sessions = 55
	cfg.mcp.max_pending_messages = 21
	cfg.mcp.session_ttl_seconds = 77
	provider_settings := ProviderRuntimeSettings{
		feishu:         FeishuRuntimeSettings{
			enabled:                    true
			open_base_url:              'https://open.feishu.test'
			reconnect_delay_ms:         1234
			token_refresh_skew_seconds: 45
			recent_event_limit:         67
			apps:                       {
				'main': FeishuAppConfig{
					app_id: 'app-1'
				}
			}
		}
		codex:          CodexRuntimeSettings{
			enabled:            true
			url:                'ws://127.0.0.1:4500'
			model:              'gpt-5.4'
			effort:             'medium'
			cwd:                '/tmp/demo'
			approval_policy:    'never'
			sandbox:            'workspace-write'
			reconnect_delay_ms: 2222
			flush_interval_ms:  3333
		}
		ollama_enabled: true
	}
	plan := LogicExecutorRuntimePlan{
		executor:            SocketWorkerExecutor{}
		worker_backend_mode: .required
		lifecycle:           PhpWorkerExecutorLifecycle{}
		bootstrap:           ExecutorBootstrapState{
			worker_sockets:          ['/tmp/a.sock']
			stream_dispatch:         true
			websocket_dispatch_mode: false
			worker_autostart:        true
			worker_cmd:              'php worker.php'
			worker_env:              {
				'APP_ENV': 'dev'
			}
		}
	}
	app := build_app_runtime(provider_settings, plan, cfg, AppRuntimeBuildConfig{
		event_log:                     '/tmp/events.ndjson'
		internal_admin_socket:         '/tmp/internal.sock'
		admin_enabled:                 true
		admin_token:                   'secret'
		assets_enabled:                true
		assets_prefix:                 '/assets'
		assets_root:                   '/tmp/assets'
		assets_root_real:              '/private/tmp/assets'
		assets_cache_control:          'public, max-age=60'
		worker_read_timeout_ms:        900
		worker_restart_backoff_ms:     100
		worker_restart_backoff_max_ms: 500
		worker_max_requests:           777
		worker_queue_capacity:         12
		worker_queue_timeout_ms:       34
		workdir:                       '/tmp/workdir'
	})
	assert app.worker_backend.sockets == ['/tmp/a.sock']
	assert app.worker_backend.cmd == 'php worker.php'
	assert app.worker_backend.env['APP_ENV'] == 'dev'
	assert app.worker_backend.read_timeout_ms == 900
	assert app.worker_backend.max_requests == 777
	assert app.worker_backend_mode == .required
	assert app.logic_executor.kind() == 'php'
	assert app.logic_executor_lifecycle == 'php_worker_host'
	assert app.internal_admin_socket == '/tmp/internal.sock'
	assert app.admin_token == 'secret'
	assert app.assets_enabled
	assert app.assets_root_real == '/private/tmp/assets'
	assert app.mcp_max_sessions == 55
	assert app.mcp_max_pending_messages == 21
	assert app.mcp_session_ttl_seconds == 77
	assert app.feishu_enabled
	assert app.feishu_open_base_url == 'https://open.feishu.test'
	assert app.feishu_apps['main'].app_id == 'app-1'
	assert app.codex_runtime.enabled
	assert app.codex_runtime.model == 'gpt-5.4'
	assert app.codex_runtime.flush_interval_ms == 3333
	assert app.ollama_enabled
}

fn test_prepare_server_runtime_files_creates_parent_dirs_and_pid_file() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_files_test')
	event_log := os.join_path(temp_dir, 'logs', 'events.ndjson')
	pid_file := os.join_path(temp_dir, 'run', 'vhttpd.pid')
	internal_socket := prepare_server_runtime_files(event_log, pid_file) or { panic(err) }
	defer {
		os.rm(pid_file) or {}
		os.rmdir_all(temp_dir) or {}
	}
	assert os.exists(os.dir(event_log))
	assert os.exists(os.dir(pid_file))
	assert os.exists(pid_file)
	pid_text := os.read_file(pid_file) or { panic(err) }
	assert pid_text.trim_space() == '${os.getpid()}'
	assert internal_socket.starts_with('/tmp/vhttpd_admin_')
}

fn test_resolve_server_runtime_config_builds_php_runtime_state() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_server_runtime_php_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	worker_entry := os.join_path(temp_dir, 'php-worker.php')
	app_entry := os.join_path(temp_dir, 'app.php')
	event_log := os.join_path(temp_dir, 'logs', 'events.ndjson')
	pid_file := os.join_path(temp_dir, 'run', 'vhttpd.pid')
	os.write_file(worker_entry, '<?php echo "worker";') or { panic(err) }
	os.write_file(app_entry, '<?php echo "app";') or { panic(err) }
	defer {
		os.rm(worker_entry) or {}
		os.rm(app_entry) or {}
		os.rm(pid_file) or {}
		os.rmdir_all(temp_dir) or {}
	}
	mut cfg := default_vhttpd_config()
	cfg.server.host = '0.0.0.0'
	cfg.server.port = 19881
	cfg.files.event_log = event_log
	cfg.files.pid_file = pid_file
	cfg.php.worker_entry = worker_entry
	cfg.php.app_entry = app_entry
	cfg.worker.autostart = true
	cfg.worker.stream_dispatch = true
	cfg.worker.websocket_dispatch = true
	cfg.worker.queue_capacity = 9
	cfg.worker.queue_timeout_ms = 88
	runtime_cfg := resolve_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert runtime_cfg.host == '0.0.0.0'
	assert runtime_cfg.port == 19881
	assert runtime_cfg.admin_host == '127.0.0.1'
	assert !runtime_cfg.admin_enabled
	assert runtime_cfg.executor_plan.executor.kind() == 'php'
	assert runtime_cfg.executor_plan.lifecycle.name() == 'php_worker_host'
	assert runtime_cfg.executor_plan.bootstrap.worker_autostart
	assert runtime_cfg.executor_plan.bootstrap.stream_dispatch
	assert runtime_cfg.executor_plan.bootstrap.websocket_dispatch_mode
	assert runtime_cfg.executor_plan.bootstrap.worker_env['VHTTPD_APP'] == app_entry
	assert runtime_cfg.executor_plan.bootstrap.worker_cmd.contains(worker_entry)
	assert runtime_cfg.app_build_cfg.event_log == event_log
	assert runtime_cfg.app_build_cfg.worker_queue_capacity == 9
	assert runtime_cfg.internal_admin_socket.starts_with('/tmp/vhttpd_admin_')
	assert os.exists(pid_file)
}

fn test_resolve_server_runtime_config_defaults_to_disabled_executor_without_app_logic() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_server_runtime_disabled_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	event_log := os.join_path(temp_dir, 'logs', 'events.ndjson')
	pid_file := os.join_path(temp_dir, 'run', 'vhttpd.pid')
	defer {
		os.rm(pid_file) or {}
		os.rmdir_all(temp_dir) or {}
	}
	mut cfg := default_vhttpd_config()
	cfg.server.host = '127.0.0.1'
	cfg.server.port = 18081
	cfg.files.event_log = event_log
	cfg.files.pid_file = pid_file
	runtime_cfg := resolve_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert runtime_cfg.executor_plan.executor.kind() == 'none'
	assert runtime_cfg.executor_plan.lifecycle.name() == 'disabled'
	assert runtime_cfg.executor_plan.worker_backend_mode == .disabled
	assert runtime_cfg.executor_plan.bootstrap.worker_sockets.len == 0
	assert !runtime_cfg.executor_plan.bootstrap.worker_autostart
	assert runtime_cfg.executor_plan.bootstrap.worker_cmd == ''
	assert os.exists(pid_file)
}

fn test_resolve_server_runtime_config_builds_vjsx_embedded_runtime_state() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_server_runtime_vjsx_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	assets_root := os.join_path(temp_dir, 'public')
	event_log := os.join_path(temp_dir, 'logs', 'events.ndjson')
	pid_file := os.join_path(temp_dir, 'run', 'vhttpd.pid')
	os.mkdir_all(assets_root) or { panic(err) }
	os.write_file(app_file, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
		os.rm(pid_file) or {}
		os.rmdir_all(temp_dir) or {}
	}
	mut cfg := default_vhttpd_config()
	cfg.server.host = '127.0.0.9'
	cfg.server.port = 18888
	cfg.files.event_log = event_log
	cfg.files.pid_file = pid_file
	cfg.executor.kind = 'vjsx'
	cfg.vjsx.app_entry = app_file
	cfg.vjsx.module_root = temp_dir
	cfg.assets.enabled = true
	cfg.assets.prefix = '/static'
	cfg.assets.root = assets_root
	cfg.assets.cache_control = 'public, max-age=300'
	cfg.admin.host = ''
	cfg.admin.port = 19983
	cfg.admin.token = 'admin-secret'
	runtime_cfg := resolve_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert runtime_cfg.host == '127.0.0.9'
	assert runtime_cfg.port == 18888
	assert runtime_cfg.admin_enabled
	assert runtime_cfg.admin_host == '127.0.0.1'
	assert runtime_cfg.admin_port == 19983
	assert runtime_cfg.admin_token == 'admin-secret'
	assert runtime_cfg.executor_plan.executor.kind() == 'vjsx'
	assert runtime_cfg.executor_plan.lifecycle.name() == 'embedded_host'
	assert runtime_cfg.executor_plan.bootstrap.worker_sockets.len == 0
	assert !runtime_cfg.executor_plan.bootstrap.worker_autostart
	assert !runtime_cfg.executor_plan.bootstrap.stream_dispatch
	assert !runtime_cfg.executor_plan.bootstrap.websocket_dispatch_mode
	assert runtime_cfg.app_build_cfg.assets_enabled
	assert runtime_cfg.app_build_cfg.assets_prefix == '/static'
	assert runtime_cfg.app_build_cfg.assets_root == assets_root
	assert runtime_cfg.app_build_cfg.assets_root_real == os.real_path(assets_root)
	assert runtime_cfg.app_build_cfg.assets_cache_control == 'public, max-age=300'
	assert os.exists(pid_file)
}

fn test_resolve_multi_server_runtime_config_keeps_single_site_compatibility() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_multi_listener_single_compat_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	worker_entry := os.join_path(temp_dir, 'php-worker.php')
	app_entry := os.join_path(temp_dir, 'app.php')
	event_log := os.join_path(temp_dir, 'logs', 'events.ndjson')
	pid_file := os.join_path(temp_dir, 'run', 'vhttpd.pid')
	os.write_file(worker_entry, '<?php echo "worker";') or { panic(err) }
	os.write_file(app_entry, '<?php echo "app";') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut cfg := default_vhttpd_config()
	cfg.server.host = '127.0.0.7'
	cfg.server.port = 18181
	cfg.files.event_log = event_log
	cfg.files.pid_file = pid_file
	cfg.php.worker_entry = worker_entry
	cfg.php.app_entry = app_entry
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert multi_cfg.single_mode
	assert multi_cfg.listeners.len == 1
	assert multi_cfg.listeners[0].id == 'default'
	assert multi_cfg.listeners[0].site_id == 'default'
	assert multi_cfg.listeners[0].runtime_cfg.host == '127.0.0.7'
	assert multi_cfg.listeners[0].runtime_cfg.port == 18181
	assert multi_cfg.listeners[0].runtime_cfg.executor_plan.executor.kind() == 'php'
}

fn test_resolve_multi_server_runtime_config_builds_listener_bound_sites() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_multi_listener_runtime_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	php_worker := os.join_path(temp_dir, 'php-worker.php')
	php_app := os.join_path(temp_dir, 'project-a.php')
	vjsx_root := os.join_path(temp_dir, 'project-b')
	vjsx_app := os.join_path(vjsx_root, 'app.mts')
	event_log := os.join_path(temp_dir, 'logs', 'events.ndjson')
	pid_file := os.join_path(temp_dir, 'run', 'vhttpd.pid')
	os.mkdir_all(vjsx_root) or { panic(err) }
	os.write_file(php_worker, '<?php echo "worker";') or { panic(err) }
	os.write_file(php_app, '<?php echo "app";') or { panic(err) }
	os.write_file(vjsx_app, 'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut cfg := default_vhttpd_config()
	cfg.files.event_log = event_log
	cfg.files.pid_file = pid_file
	cfg.config_path = os.join_path(temp_dir, 'vhttpd.toml')
	cfg.admin.host = '127.0.0.1'
	cfg.admin.port = 19983
	cfg.admin.token = 'admin-secret'
	cfg.listeners = {
		'project_a': ListenerConfig{
			host: '127.0.0.1'
			port: 18081
			site: 'project_a'
		}
		'project_b': ListenerConfig{
			host: '127.0.0.1'
			port: 18082
			site: 'project_b'
		}
	}
	cfg.sites = {
		'project_a': SiteConfig{
			project_root: temp_dir
			executor:     ExecutorConfig{
				kind: 'php'
			}
			php:          PhpConfig{
				worker_entry: php_worker
				app_entry:    php_app
			}
		}
		'project_b': SiteConfig{
			project_root: vjsx_root
			executor:     ExecutorConfig{
				kind: 'vjsx'
			}
			vjsx:         VjsxConfig{
				app_entry:       './app.mts'
				module_root:     '.'
				runtime_profile: 'node'
				thread_count:    2
			}
		}
	}
	multi_cfg := resolve_multi_server_runtime_config([]string{}, cfg) or { panic(err) }
	assert !multi_cfg.single_mode
	assert multi_cfg.listeners.len == 2
	assert multi_cfg.listeners[0].id == 'project_a'
	assert multi_cfg.listeners[0].site_id == 'project_a'
	assert multi_cfg.listeners[0].runtime_cfg.host == '127.0.0.1'
	assert multi_cfg.listeners[0].runtime_cfg.port == 18081
	assert multi_cfg.listeners[0].runtime_cfg.executor_plan.executor.kind() == 'php'
	assert multi_cfg.listeners[0].site_cfg.php.app_entry == php_app
	assert multi_cfg.listeners[0].runtime_cfg.admin_enabled
	assert multi_cfg.listeners[0].runtime_cfg.admin_port == 19983
	assert multi_cfg.listeners[1].id == 'project_b'
	assert multi_cfg.listeners[1].site_id == 'project_b'
	assert multi_cfg.listeners[1].runtime_cfg.host == '127.0.0.1'
	assert multi_cfg.listeners[1].runtime_cfg.port == 18082
	assert multi_cfg.listeners[1].runtime_cfg.executor_plan.executor.kind() == 'vjsx'
	assert multi_cfg.listeners[1].site_cfg.vjsx.app_entry == vjsx_app
	assert multi_cfg.listeners[1].site_cfg.vjsx.module_root == vjsx_root
	assert !multi_cfg.listeners[1].runtime_cfg.admin_enabled
	assert os.exists(pid_file)
}

fn test_resolve_multi_server_runtime_config_rejects_unknown_site_binding() {
	mut cfg := default_vhttpd_config()
	cfg.listeners = {
		'broken': ListenerConfig{
			host: '127.0.0.1'
			port: 19001
			site: 'missing'
		}
	}
	cfg.sites = {
		'other': SiteConfig{}
	}
	resolve_multi_server_runtime_config([]string{}, cfg) or {
		assert err.msg() == 'multi_listener_unknown_site:broken:missing'
		return
	}
	assert false
}

fn test_site_config_as_vhttpd_config_inherits_global_defaults() {
	mut cfg := default_vhttpd_config()
	cfg.executor.kind = 'vjsx'
	cfg.assets.enabled = true
	cfg.assets.prefix = '/shared'
	cfg.assets.root = '/tmp/shared-assets'
	cfg.codex.enabled = true
	cfg.codex.model = 'gpt-5.4'
	cfg.mcp.max_sessions = 77
	site_cfg := SiteConfig{
		project_root: '/tmp/project-a'
		vjsx:         VjsxConfig{
			app_entry: './app.mts'
		}
	}
	derived := site_config_as_vhttpd_config(cfg, site_cfg)
	assert derived.paths.root == '/tmp/project-a'
	assert derived.executor.kind == 'vjsx'
	assert derived.vjsx.app_entry == './app.mts'
	assert derived.assets.enabled
	assert derived.assets.prefix == '/shared'
	assert derived.assets.root == '/tmp/shared-assets'
	assert derived.codex.enabled
	assert derived.codex.model == 'gpt-5.4'
	assert derived.mcp.max_sessions == 77
	assert derived.listeners.len == 0
	assert derived.sites.len == 0
}

fn test_load_vhttpd_config_supports_site_websocket_affinity() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_websocket_affinity_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[sites.relay]
host = "0.0.0.0"
port = 19901
executor = "vjsx"
websocket_dispatch = true
websocket_affinity.enabled = true
websocket_affinity.source = "app"
websocket_affinity.key = "serverId"
websocket_affinity.scope = "lane"
websocket_affinity.fallback = "reject"
') or { panic(err) }
	defer {
		os.rm(config_file) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	site := cfg.sites['relay']
	assert site.websocket_affinity.enabled
	assert site.websocket_affinity.source == 'app'
	assert site.websocket_affinity.key == 'serverId'
	assert site.websocket_affinity.scope == 'lane'
	assert site.websocket_affinity.fallback == 'reject'
}

fn test_load_vhttpd_config_supports_site_websocket_actor() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_site_websocket_actor_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[sites.relay]
host = "0.0.0.0"
port = 19901
executor = "vjsx"
websocket_dispatch = true
websocket_actor.enabled = true
websocket_actor.fallback = "reject"
websocket_actor.queue_timeout_ms = 1234
websocket_actor.max_queue_per_key = 77
websocket_actor.events = ["open", "message"]
websocket_actor.sources = [
  { type = "connection_cache" },
  { type = "query", key = "connectionId", class = "conn" },
  { type = "app" },
]
') or { panic(err) }
	defer {
		os.rm(config_file) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	site := cfg.sites['relay']
	assert site.websocket_actor.enabled
	assert site.websocket_actor.fallback == 'reject'
	assert site.websocket_actor.queue_timeout_ms == 1234
	assert site.websocket_actor.max_queue_per_key == 77
	assert site.websocket_actor.events == ['open', 'message']
	assert site.websocket_actor.sources.len == 3
	assert site.websocket_actor.sources[0].typ == 'connection_cache'
	assert site.websocket_actor.sources[1].typ == 'query'
	assert site.websocket_actor.sources[1].key == 'connectionId'
	assert site.websocket_actor.sources[1].class_name == 'conn'
	assert site.websocket_actor.sources[2].typ == 'app'
}

fn test_site_config_as_vhttpd_config_merges_site_websocket_affinity() {
	mut base := default_vhttpd_config()
	base.websocket_affinity = WebSocketAffinityConfig{
		enabled:  true
		source:   'header'
		key:      'x-session-id'
		scope:    'lane'
		fallback: 'round_robin'
	}
	derived := site_config_as_vhttpd_config(base, SiteConfig{
		websocket_affinity: WebSocketAffinityConfig{
			enabled:  true
			source:   'app'
			key:      'serverId'
			scope:    'lane'
			fallback: 'reject'
		}
	})
	assert derived.websocket_affinity.enabled
	assert derived.websocket_affinity.source == 'app'
	assert derived.websocket_affinity.key == 'serverId'
	assert derived.websocket_affinity.scope == 'lane'
	assert derived.websocket_affinity.fallback == 'reject'
}

fn test_site_config_as_vhttpd_config_merges_site_websocket_actor() {
	mut base := default_vhttpd_config()
	base.websocket_actor = WebSocketActorConfig{
		enabled:          true
		fallback:         'unkeyed'
		queue_timeout_ms: 1000
		max_queue_per_key: 16
		events:           ['open']
		sources: [
			WebSocketActorSourceConfig{
				typ: 'query'
				key: 'serverId'
				class_name: 'session'
			},
		]
	}
	derived := site_config_as_vhttpd_config(base, SiteConfig{
		websocket_actor: WebSocketActorConfig{
			enabled:          true
			fallback:         'reject'
			queue_timeout_ms: 30000
			max_queue_per_key: 1024
			events:           ['open', 'message', 'close']
			sources: [
				WebSocketActorSourceConfig{
					typ: 'connection_cache'
				},
				WebSocketActorSourceConfig{
					typ:        'query'
					key:        'connectionId'
					class_name: 'conn'
				},
			]
		}
	})
	assert derived.websocket_actor.enabled
	assert derived.websocket_actor.fallback == 'reject'
	assert derived.websocket_actor.queue_timeout_ms == 30000
	assert derived.websocket_actor.max_queue_per_key == 1024
	assert derived.websocket_actor.events == ['open', 'message', 'close']
	assert derived.websocket_actor.sources.len == 2
	assert derived.websocket_actor.sources[0].typ == 'connection_cache'
	assert derived.websocket_actor.sources[1].key == 'connectionId'
	assert derived.websocket_actor.sources[1].class_name == 'conn'
}

fn test_resolve_embedded_host_runtime_config_normalizes_paths_and_lane_defaults() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_embedded_host_runtime_test')
	os.mkdir_all(os.join_path(temp_dir, 'sig')) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	os.write_file(app_file, 'export default {};') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := resolve_embedded_host_runtime_config(['--app', app_file, '--module-root',
		os.join_path(temp_dir, 'modules'), '--build-root', os.join_path(temp_dir, 'cache'),
		'--signature-root', os.join_path(temp_dir, 'sig'), '--signature-include', '**/*.mts',
		'--signature-exclude', 'tmp/**', '--profile', 'node', '--lanes', '0'], EmbeddedHostRuntimeConfig{
		runtime_profile: 'script'
		lane_count:      3
		max_requests:    9
		enable_fs:       true
		enable_process:  true
		enable_network:  true
	}, EmbeddedHostCliOverrides{
		app_entry_flag:         '--app'
		module_root_flag:       '--module-root'
		build_root_flag:        '--build-root'
		signature_root_flag:    '--signature-root'
		signature_include_flag: '--signature-include'
		signature_exclude_flag: '--signature-exclude'
		runtime_profile_flag:   '--profile'
		lane_count_flag:        '--lanes'
	}) or { panic(err) }
	assert cfg.app_entry == app_file
	assert cfg.module_root == os.join_path(temp_dir, 'modules')
	assert cfg.build_root == os.join_path(temp_dir, 'cache')
	assert cfg.signature_root == os.join_path(temp_dir, 'sig')
	assert cfg.signature_include == ['**/*.mts']
	assert cfg.signature_exclude == ['tmp/**']
	assert cfg.runtime_profile == 'node'
	assert cfg.lane_count == 1
	assert cfg.max_requests == 9
	assert cfg.enable_fs
	assert cfg.enable_process
	assert cfg.enable_network
}

fn test_shutdown_app_runtime_stops_lifecycle_and_cleans_runtime_files() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_shutdown_runtime_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	event_log := os.join_path(temp_dir, 'events.ndjson')
	pid_file := os.join_path(temp_dir, 'vhttpd.pid')
	internal_socket := os.join_path(temp_dir, 'internal-admin.sock')
	os.write_file(event_log, '') or { panic(err) }
	os.write_file(pid_file, '${os.getpid()}') or { panic(err) }
	os.write_file(internal_socket, 'socket') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut executor_state := &TestShutdownLogicExecutorState{}
	mut app := App{
		event_log:      event_log
		logic_executor: TestShutdownLogicExecutor{
			state: executor_state
		}
		providers:      ProviderHost{
			specs: {
				'test': ProviderSpec{
					name:        'test'
					enabled:     true
					has_runtime: true
					provider:    TestShutdownProvider{}
					handler:     NoopProviderCommandHandler{}
					runtime:     TestShutdownProviderRuntime{}
				}
			}
		}
	}
	runtime_cfg := ServerRuntimeConfig{
		pid_file:              pid_file
		internal_admin_socket: internal_socket
		executor_plan:         LogicExecutorRuntimePlan{
			executor:            TestShutdownLogicExecutor{
				state: executor_state
			}
			worker_backend_mode: .disabled
			lifecycle:           TestShutdownExecutorLifecycle{}
			bootstrap:           ExecutorBootstrapState{}
		}
	}
	shutdown_app_runtime(mut app, runtime_cfg)
	assert executor_state.close_called
	assert !os.exists(pid_file)
	assert !os.exists(internal_socket)
	rows := os.read_lines(event_log) or { panic(err) }
	mut non_empty_rows := []string{}
	for row in rows {
		if row.trim_space() != '' {
			non_empty_rows << row
		}
	}
	assert non_empty_rows.len == 3
	assert non_empty_rows[0].contains('"type":"server.stopped"')
	assert non_empty_rows[1].contains('"type":"test.executor.stopped"')
	assert non_empty_rows[2].contains('"type":"test.provider.stopped"')
}

fn test_paseo_relay_example_config_enables_websocket_dispatch() {
	config_path := os.join_path(os.dir(@FILE), '..', 'examples', 'paseo-relay', 'paseo-relay.toml')
	cfg := load_vhttpd_config(['--config', config_path]) or { panic(err) }
	assert cfg.worker.websocket_dispatch
	assert cfg.sites['paseo_relay'].websocket_affinity.enabled
	assert cfg.sites['paseo_relay'].websocket_affinity.source == 'app'
	assert cfg.sites['paseo_relay'].websocket_affinity.key == 'serverId'
	assert cfg.sites['paseo_relay'].websocket_affinity.fallback == 'reject'
	assert cfg.sites['paseo_relay'].websocket_actor.enabled
	assert cfg.sites['paseo_relay'].websocket_actor.sources.len == 3
	assert cfg.sites['paseo_relay'].websocket_actor.sources[0].typ == 'connection_cache'
	assert cfg.sites['paseo_relay'].websocket_actor.sources[1].key == 'connectionId'
	assert cfg.sites['paseo_relay'].websocket_actor.sources[1].class_name == 'conn'
	runtime := resolve_multi_server_runtime_config(['--config', config_path], cfg) or {
		panic(err)
	}
	assert runtime.listeners.len == 1
	assert runtime.listeners[0].runtime_cfg.executor_plan.bootstrap.websocket_dispatch_mode
	assert runtime.listeners[0].site_cfg.websocket_affinity.enabled
	assert runtime.listeners[0].site_cfg.websocket_affinity.key == 'serverId'
	assert runtime.listeners[0].site_cfg.websocket_actor.enabled
	assert runtime.listeners[0].site_cfg.websocket_actor.sources.len == 3
}
