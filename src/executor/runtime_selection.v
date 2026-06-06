module executor

import config

pub struct ExecutorRuntimeSelection {
pub:
	executor            LogicExecutor
	worker_backend_mode WorkerBackendMode     = .required
	lifecycle           LogicExecutorLifecycle = php_worker_executor_lifecycle()
}

fn ExecutorRuntimeSelection.infer_kind_from_config(cfg config.VhttpdConfig) string {
	if cfg.php.worker_entry.trim_space() != '' || cfg.php.app_entry.trim_space() != '' {
		return 'php'
	}
	if cfg.vjsx.app_entry.trim_space() != '' || cfg.vjsx.module_root.trim_space() != ''
		|| cfg.vjsx.build_root.trim_space() != '' {
		return 'vjsx'
	}
	return 'none'
}

pub fn ExecutorRuntimeSelection.resolve(args []string, cfg config.VhttpdConfig, factory ExecutorFactory) !ExecutorRuntimeSelection {
	mut kind := config.CliArgs.string_or(args, '--executor', cfg.executor.kind).trim_space()
	if kind == '' {
		kind = ExecutorRuntimeSelection.infer_kind_from_config(cfg)
	}
	spec := builtin_executor_spec_find(kind)!
	return spec.runtime_selection(args, cfg, factory)
}
