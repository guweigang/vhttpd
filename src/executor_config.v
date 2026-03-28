module main

import os

pub struct ExecutorRuntimeSelection {
pub:
	executor            LogicExecutor
	worker_backend_mode WorkerBackendMode      = .required
	lifecycle           LogicExecutorLifecycle = PhpWorkerExecutorLifecycle{}
}

fn shell_quote_arg(raw string) string {
	if raw == '' {
		return "''"
	}
	return "'" + raw.replace("'", '\'"\'"\'') + "'"
}

fn validate_php_runtime_config(php_cfg PhpConfig) ! {
	worker_entry := php_cfg.worker_entry.trim_space()
	if worker_entry == '' {
		return error('php_worker_entry_missing')
	}
	if !os.exists(worker_entry) {
		return error('php_worker_entry_not_found:${worker_entry}')
	}
	app_entry := php_cfg.app_entry.trim_space()
	if app_entry != '' && !os.exists(app_entry) {
		return error('php_app_entry_not_found:${app_entry}')
	}
	for ext in php_cfg.extensions {
		ext_path := ext.trim_space()
		if ext_path == '' {
			continue
		}
		if !os.exists(ext_path) {
			return error('php_extension_not_found:${ext_path}')
		}
	}
}

fn build_php_runtime_config(args []string, cfg VhttpdConfig) !PhpConfig {
	mut php_cfg := cfg.php
	php_cfg.bin = arg_string_or(args, '--php-bin', php_cfg.bin).trim_space()
	php_cfg.worker_entry = arg_string_or(args, '--php-worker-entry', php_cfg.worker_entry).trim_space()
	php_cfg.app_entry = arg_string_or(args, '--php-app-entry', php_cfg.app_entry).trim_space()
	if arg_has(args, '--php-extension') {
		php_cfg.extensions = arg_string_list_or(args, '--php-extension', []string{})
	}
	if arg_has(args, '--php-arg') {
		php_cfg.args = arg_string_list_or(args, '--php-arg', []string{})
	}
	validate_php_runtime_config(php_cfg)!
	return php_cfg
}

fn build_php_worker_command(php_cfg PhpConfig) !string {
	mut bin := php_cfg.bin.trim_space()
	if bin == '' {
		bin = 'php'
	}
	worker_entry := php_cfg.worker_entry.trim_space()
	if worker_entry == '' {
		return error('php_worker_entry_missing')
	}
	mut parts := []string{}
	parts << bin
	for ext in php_cfg.extensions {
		ext_path := ext.trim_space()
		if ext_path == '' {
			continue
		}
		parts << '-d'
		parts << 'extension=${ext_path}'
	}
	for arg in php_cfg.args {
		if arg.trim_space() == '' {
			continue
		}
		parts << arg
	}
	parts << worker_entry
	return parts.map(shell_quote_arg(it)).join(' ')
}

fn build_php_worker_env(worker_env map[string]string, php_cfg PhpConfig) map[string]string {
	mut env := worker_env.clone()
	if php_cfg.app_entry.trim_space() != '' {
		env['VHTTPD_APP'] = php_cfg.app_entry
	}
	return env
}

fn build_vjsx_runtime_config(args []string, cfg VhttpdConfig) !VjsxRuntimeFacadeConfig {
	embedded_cfg := resolve_embedded_host_runtime_config(args, EmbeddedHostRuntimeConfig{
		app_entry:         cfg.vjsx.app_entry
		module_root:       cfg.vjsx.module_root
		signature_root:    cfg.vjsx.signature_root
		signature_include: cfg.vjsx.signature_include.clone()
		signature_exclude: cfg.vjsx.signature_exclude.clone()
		runtime_profile:   cfg.vjsx.runtime_profile
		lane_count:        cfg.vjsx.thread_count
		max_requests:      cfg.vjsx.max_requests
		enable_fs:         cfg.vjsx.enable_fs
		enable_process:    cfg.vjsx.enable_process
		enable_network:    cfg.vjsx.enable_network
	}, EmbeddedHostCliOverrides{
		app_entry_flag:         '--vjsx-entry'
		module_root_flag:       '--vjsx-module-root'
		signature_root_flag:    '--vjsx-signature-root'
		signature_include_flag: '--vjsx-signature-include'
		signature_exclude_flag: '--vjsx-signature-exclude'
		runtime_profile_flag:   '--vjsx-runtime-profile'
		lane_count_flag:        '--vjsx-thread-count'
	}) or {
		match err.msg() {
			'embedded_host_missing_app_entry' {
				return error('inproc_vjsx_executor_missing_app_entry')
			}
			else {
				if err.msg().starts_with('embedded_host_app_entry_not_found:') {
					return error(err.msg().replace('embedded_host_app_entry_not_found:',
						'inproc_vjsx_executor_app_entry_not_found:'))
				}
				return error(err.msg())
			}
		}
	}
	return VjsxRuntimeFacadeConfig{
		app_entry:         embedded_cfg.app_entry
		module_root:       embedded_cfg.module_root
		signature_root:    embedded_cfg.signature_root
		signature_include: embedded_cfg.signature_include.clone()
		signature_exclude: embedded_cfg.signature_exclude.clone()
		runtime_profile:   embedded_cfg.runtime_profile
		thread_count:      embedded_cfg.lane_count
		max_requests:      embedded_cfg.max_requests
		enable_fs:         embedded_cfg.enable_fs
		enable_process:    embedded_cfg.enable_process
		enable_network:    embedded_cfg.enable_network
	}
}

fn resolve_executor_runtime(args []string, cfg VhttpdConfig) !ExecutorRuntimeSelection {
	kind := normalize_executor_kind(arg_string_or(args, '--executor', cfg.executor.kind))!
	spec := builtin_logic_executor_spec(kind)!
	return ExecutorRuntimeSelection{
		executor:            build_builtin_logic_executor(kind, args, cfg)!
		worker_backend_mode: spec.worker_backend_mode
		lifecycle:           build_builtin_logic_executor_lifecycle(kind)!
	}
}
