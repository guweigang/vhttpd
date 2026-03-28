module main

enum BuiltinLogicExecutorFactoryKind {
	socket_worker
	inproc_vjsx
}

pub struct LogicExecutorConfigSurface {
pub:
	section                string
	app_entry_flag         string @[json: 'app_entry_flag']
	worker_entry_flag      string @[json: 'worker_entry_flag']
	module_root_flag       string @[json: 'module_root_flag']
	signature_root_flag    string @[json: 'signature_root_flag']
	signature_include_flag string @[json: 'signature_include_flag']
	signature_exclude_flag string @[json: 'signature_exclude_flag']
	runtime_profile_flag   string @[json: 'runtime_profile_flag']
	lane_count_flag        string @[json: 'lane_count_flag']
}

struct BuiltinLogicExecutorSpec {
pub:
	kind                string
	aliases             []string
	provider            string
	logic_model         LogicExecutorModel
	worker_backend_mode WorkerBackendMode
	lifecycle           LogicExecutorLifecycle
	factory             BuiltinLogicExecutorFactoryKind
	config_surface      LogicExecutorConfigSurface
}

pub struct AdminLogicExecutorSpecSnapshot {
pub:
	kind                     string
	aliases                  []string
	logic_provider           string                     @[json: 'logic_provider']
	logic_executor_lifecycle string                     @[json: 'logic_executor_lifecycle']
	logic_executor_model     string                     @[json: 'logic_executor_model']
	worker_backend_mode      string                     @[json: 'worker_backend_mode']
	config_surface           LogicExecutorConfigSurface @[json: 'config_surface']
}

fn builtin_logic_executor_specs() []BuiltinLogicExecutorSpec {
	return [
		BuiltinLogicExecutorSpec{
			kind:                'php'
			aliases:             ['php_worker', 'php-worker']
			provider:            'php-worker'
			logic_model:         .worker
			worker_backend_mode: .required
			lifecycle:           PhpWorkerExecutorLifecycle{}
			factory:             .socket_worker
			config_surface:      LogicExecutorConfigSurface{
				section:           'php'
				app_entry_flag:    '--php-app-entry'
				worker_entry_flag: '--php-worker-entry'
			}
		},
		BuiltinLogicExecutorSpec{
			kind:                'vjsx'
			aliases:             []string{}
			provider:            'vjsx'
			logic_model:         .embedded
			worker_backend_mode: .disabled
			lifecycle:           EmbeddedExecutorLifecycle{}
			factory:             .inproc_vjsx
			config_surface:      LogicExecutorConfigSurface{
				section:                'vjsx'
				app_entry_flag:         '--vjsx-entry'
				module_root_flag:       '--vjsx-module-root'
				signature_root_flag:    '--vjsx-signature-root'
				signature_include_flag: '--vjsx-signature-include'
				signature_exclude_flag: '--vjsx-signature-exclude'
				runtime_profile_flag:   '--vjsx-runtime-profile'
				lane_count_flag:        '--vjsx-thread-count'
			}
		},
	]
}

fn builtin_logic_executor_kinds() []string {
	return builtin_logic_executor_specs().map(it.kind)
}

fn builtin_logic_executor_kinds_label() string {
	return builtin_logic_executor_kinds().join(' | ')
}

fn normalize_builtin_logic_executor_kind(raw string) string {
	return raw.trim_space().to_lower().replace('-', '_')
}

fn (spec BuiltinLogicExecutorSpec) matches_kind(raw string) bool {
	normalized := normalize_builtin_logic_executor_kind(raw)
	if normalized == '' {
		return spec.kind == 'php'
	}
	if normalized == spec.kind {
		return true
	}
	for alias in spec.aliases {
		if normalized == alias.replace('-', '_') {
			return true
		}
	}
	return false
}

fn (spec BuiltinLogicExecutorSpec) admin_snapshot() AdminLogicExecutorSpecSnapshot {
	return AdminLogicExecutorSpecSnapshot{
		kind:                     spec.kind
		aliases:                  spec.aliases.clone()
		logic_provider:           spec.provider
		logic_executor_lifecycle: spec.lifecycle.name()
		logic_executor_model:     spec.logic_model.str()
		worker_backend_mode:      spec.worker_backend_mode.str()
		config_surface:           spec.config_surface
	}
}

fn (spec BuiltinLogicExecutorSpec) resolve_php_runtime_config(args []string, cfg VhttpdConfig) !PhpConfig {
	if spec.factory != .socket_worker {
		return error('builtin_logic_executor_php_runtime_config_unsupported:${spec.kind}')
	}
	mut php_cfg := cfg.php
	php_cfg.bin = arg_string_or(args, '--php-bin', php_cfg.bin).trim_space()
	php_cfg.worker_entry = arg_string_or(args, spec.config_surface.worker_entry_flag,
		php_cfg.worker_entry).trim_space()
	php_cfg.app_entry = arg_string_or(args, spec.config_surface.app_entry_flag, php_cfg.app_entry).trim_space()
	if arg_has(args, '--php-extension') {
		php_cfg.extensions = arg_string_list_or(args, '--php-extension', []string{})
	}
	if arg_has(args, '--php-arg') {
		php_cfg.args = arg_string_list_or(args, '--php-arg', []string{})
	}
	validate_php_runtime_config(php_cfg)!
	return php_cfg
}

fn (spec BuiltinLogicExecutorSpec) resolve_embedded_host_runtime_config(args []string, cfg VhttpdConfig) !EmbeddedHostRuntimeConfig {
	if spec.factory != .inproc_vjsx {
		return error('builtin_logic_executor_embedded_host_runtime_config_unsupported:${spec.kind}')
	}
	return resolve_embedded_host_runtime_config(args, EmbeddedHostRuntimeConfig{
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
		app_entry_flag:         spec.config_surface.app_entry_flag
		module_root_flag:       spec.config_surface.module_root_flag
		signature_root_flag:    spec.config_surface.signature_root_flag
		signature_include_flag: spec.config_surface.signature_include_flag
		signature_exclude_flag: spec.config_surface.signature_exclude_flag
		runtime_profile_flag:   spec.config_surface.runtime_profile_flag
		lane_count_flag:        spec.config_surface.lane_count_flag
	})!
}

fn (spec BuiltinLogicExecutorSpec) resolve_vjsx_runtime_config(args []string, cfg VhttpdConfig) !VjsxRuntimeFacadeConfig {
	if spec.factory != .inproc_vjsx {
		return error('builtin_logic_executor_vjsx_runtime_config_unsupported:${spec.kind}')
	}
	embedded_cfg := spec.resolve_embedded_host_runtime_config(args, cfg) or {
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

fn (spec BuiltinLogicExecutorSpec) build_executor(args []string, cfg VhttpdConfig) !LogicExecutor {
	match spec.factory {
		.socket_worker {
			return SocketWorkerExecutor{}
		}
		.inproc_vjsx {
			return new_inproc_vjsx_executor(spec.resolve_vjsx_runtime_config(args, cfg)!)
		}
	}
}

fn (spec BuiltinLogicExecutorSpec) runtime_selection(args []string, cfg VhttpdConfig) !ExecutorRuntimeSelection {
	return ExecutorRuntimeSelection{
		executor:            spec.build_executor(args, cfg)!
		worker_backend_mode: spec.worker_backend_mode
		lifecycle:           spec.lifecycle
	}
}

fn normalize_executor_kind(raw string) !string {
	spec := builtin_logic_executor_spec(raw)!
	return spec.kind
}

fn builtin_logic_executor_spec(kind string) !BuiltinLogicExecutorSpec {
	for spec in builtin_logic_executor_specs() {
		if spec.matches_kind(kind) {
			return spec
		}
	}
	return error('unsupported executor kind: ${kind}')
}

pub fn (mut app App) admin_logic_executor_specs_snapshot() []AdminLogicExecutorSpecSnapshot {
	_ = app
	specs := builtin_logic_executor_specs()
	mut snapshots := []AdminLogicExecutorSpecSnapshot{cap: specs.len}
	for spec in specs {
		snapshots << spec.admin_snapshot()
	}
	return snapshots
}
