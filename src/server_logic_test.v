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
	assert cfg.vjsx.runtime_profile == 'node'
	assert cfg.vjsx.thread_count == 3
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
	assert cfg.vjsx.signature_root == expected_vjsx_sig_root
	assert cfg.vjsx.signature_include[0] == 'apps/**/*.mts'
	assert cfg.assets.root == expected_assets_root
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

fn test_resolve_executor_runtime_defaults_to_php() {
	selection := resolve_executor_runtime([]string{}, default_vhttpd_config()) or { panic(err) }
	assert selection.lifecycle.name() == 'php_worker_host'
	assert selection.executor.model() == .worker
	assert selection.executor.kind() == 'php'
	assert selection.executor.provider() == 'php-worker'
	assert selection.worker_backend_mode == .required
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

fn test_build_php_runtime_config_overrides_from_cli() {
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
	php_cfg := build_php_runtime_config(['--php-bin', 'php82', '--php-worker-entry', worker_entry,
		'--php-app-entry', app_entry, '--php-extension', ext_a, '--php-extension', ext_b, '--php-arg',
		'-d', '--php-arg', 'memory_limit=512M'], cfg) or { panic(err) }
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

fn test_build_php_runtime_config_reports_missing_paths() {
	mut cfg := default_vhttpd_config()
	cfg.php.bin = 'php'
	cfg.php.worker_entry = '/tmp/definitely-missing-worker'
	build_php_runtime_config([]string{}, cfg) or {
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
	assert normalize_executor_kind('') or { panic(err) } == 'php'
	assert normalize_executor_kind('php-worker') or { panic(err) } == 'php'
	assert normalize_executor_kind('php_worker') or { panic(err) } == 'php'
	assert normalize_executor_kind('vjsx') or { panic(err) } == 'vjsx'
}

fn test_builtin_logic_executor_spec_exposes_runtime_models() {
	php_spec := builtin_logic_executor_spec('php') or { panic(err) }
	assert php_spec.matches_kind('')
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
	assert snapshot.len == 2
	assert snapshot[0].kind == 'php'
	assert snapshot[0].logic_provider == 'php-worker'
	assert snapshot[0].logic_executor_lifecycle == 'php_worker_host'
	assert snapshot[0].logic_executor_model == 'worker'
	assert snapshot[0].worker_backend_mode == 'required'
	assert snapshot[0].config_surface.section == 'php'
	assert snapshot[0].config_surface.worker_entry_flag == '--php-worker-entry'
	assert 'php-worker' in snapshot[0].aliases
	assert snapshot[1].kind == 'vjsx'
	assert snapshot[1].logic_provider == 'vjsx'
	assert snapshot[1].logic_executor_lifecycle == 'embedded_host'
	assert snapshot[1].logic_executor_model == 'embedded'
	assert snapshot[1].worker_backend_mode == 'disabled'
	assert snapshot[1].config_surface.section == 'vjsx'
	assert snapshot[1].config_surface.app_entry_flag == '--vjsx-entry'
	assert snapshot[1].config_surface.signature_root_flag == '--vjsx-signature-root'
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
	assert snapshot.len == 2
	assert snapshot[0].kind == 'php'
	assert snapshot[0].logic_provider == 'php-worker'
	assert snapshot[0].logic_executor_lifecycle == 'php_worker_host'
	assert snapshot[0].config_surface.section == 'php'
	assert snapshot[1].kind == 'vjsx'
	assert snapshot[1].logic_provider == 'vjsx'
	assert snapshot[1].logic_executor_lifecycle == 'embedded_host'
	assert snapshot[1].config_surface.section == 'vjsx'
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
	assert !state.websocket_dispatch_mode
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
	assert !plan.bootstrap.websocket_dispatch_mode
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

fn test_resolve_embedded_host_runtime_config_normalizes_paths_and_lane_defaults() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_embedded_host_runtime_test')
	os.mkdir_all(os.join_path(temp_dir, 'sig')) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	os.write_file(app_file, 'export default {};') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	cfg := resolve_embedded_host_runtime_config(['--app', app_file, '--module-root',
		os.join_path(temp_dir, 'modules'), '--signature-root', os.join_path(temp_dir, 'sig'),
		'--signature-include', '**/*.mts', '--signature-exclude', 'tmp/**', '--profile', 'node',
		'--lanes', '0'], EmbeddedHostRuntimeConfig{
		runtime_profile: 'script'
		lane_count:      3
		max_requests:    9
		enable_fs:       true
		enable_process:  true
		enable_network:  true
	}, EmbeddedHostCliOverrides{
		app_entry_flag:         '--app'
		module_root_flag:       '--module-root'
		signature_root_flag:    '--signature-root'
		signature_include_flag: '--signature-include'
		signature_exclude_flag: '--signature-exclude'
		runtime_profile_flag:   '--profile'
		lane_count_flag:        '--lanes'
	}) or { panic(err) }
	assert cfg.app_entry == app_file
	assert cfg.module_root == os.join_path(temp_dir, 'modules')
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
	mut app := App{
		event_log: event_log
		providers: ProviderHost{
			specs: {
				'test': ProviderSpec{
					name:        'test'
					enabled:     true
					has_runtime: true
					runtime:     TestShutdownProviderRuntime{}
				}
			}
		}
	}
	runtime_cfg := ServerRuntimeConfig{
		pid_file:              pid_file
		internal_admin_socket: internal_socket
		executor_plan:         LogicExecutorRuntimePlan{
			executor:            InProcVjsxExecutor{}
			worker_backend_mode: .disabled
			lifecycle:           TestShutdownExecutorLifecycle{}
			bootstrap:           ExecutorBootstrapState{}
		}
	}
	shutdown_app_runtime(mut app, runtime_cfg)
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
