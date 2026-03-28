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

fn resolve_executor_runtime(args []string, cfg VhttpdConfig) !ExecutorRuntimeSelection {
	spec := builtin_logic_executor_spec(arg_string_or(args, '--executor', cfg.executor.kind))!
	return spec.runtime_selection(args, cfg)
}
