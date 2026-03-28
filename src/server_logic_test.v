module main

import os

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
	assert php_spec.logic_model == .worker
	assert php_spec.worker_backend_mode == .required
	vjsx_spec := builtin_logic_executor_spec('vjsx') or { panic(err) }
	assert vjsx_spec.logic_model == .embedded
	assert vjsx_spec.worker_backend_mode == .disabled
}
