module main

enum BuiltinLogicExecutorFactoryKind {
	socket_worker
	inproc_vjsx
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
}

pub struct AdminLogicExecutorSpecSnapshot {
pub:
	kind                     string
	aliases                  []string
	logic_provider           string @[json: 'logic_provider']
	logic_executor_lifecycle string @[json: 'logic_executor_lifecycle']
	logic_executor_model     string @[json: 'logic_executor_model']
	worker_backend_mode      string @[json: 'worker_backend_mode']
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
		},
		BuiltinLogicExecutorSpec{
			kind:                'vjsx'
			aliases:             []string{}
			provider:            'vjsx'
			logic_model:         .embedded
			worker_backend_mode: .disabled
			lifecycle:           EmbeddedExecutorLifecycle{}
			factory:             .inproc_vjsx
		},
	]
}

fn builtin_logic_executor_kinds() []string {
	return builtin_logic_executor_specs().map(it.kind)
}

fn builtin_logic_executor_kinds_label() string {
	return builtin_logic_executor_kinds().join(' | ')
}

fn normalize_executor_kind(raw string) !string {
	normalized := raw.trim_space().to_lower().replace('-', '_')
	for spec in builtin_logic_executor_specs() {
		if normalized == '' && spec.kind == 'php' {
			return spec.kind
		}
		if normalized == spec.kind {
			return spec.kind
		}
		for alias in spec.aliases {
			if normalized == alias.replace('-', '_') {
				return spec.kind
			}
		}
	}
	return error('unsupported executor kind: ${raw}')
}

fn builtin_logic_executor_spec(kind string) !BuiltinLogicExecutorSpec {
	normalized := normalize_executor_kind(kind)!
	for spec in builtin_logic_executor_specs() {
		if spec.kind == normalized {
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
		snapshots << AdminLogicExecutorSpecSnapshot{
			kind:                     spec.kind
			aliases:                  spec.aliases.clone()
			logic_provider:           spec.provider
			logic_executor_lifecycle: spec.lifecycle.name()
			logic_executor_model:     spec.logic_model.str()
			worker_backend_mode:      spec.worker_backend_mode.str()
		}
	}
	return snapshots
}

fn build_builtin_logic_executor_from_spec(spec BuiltinLogicExecutorSpec, args []string, cfg VhttpdConfig) !LogicExecutor {
	match spec.factory {
		.socket_worker {
			return SocketWorkerExecutor{}
		}
		.inproc_vjsx {
			return new_inproc_vjsx_executor(build_vjsx_runtime_config(args, cfg)!)
		}
	}
}

fn build_builtin_logic_executor(kind string, args []string, cfg VhttpdConfig) !LogicExecutor {
	spec := builtin_logic_executor_spec(kind)!
	return build_builtin_logic_executor_from_spec(spec, args, cfg)
}

fn build_builtin_logic_executor_lifecycle(kind string) !LogicExecutorLifecycle {
	spec := builtin_logic_executor_spec(kind)!
	return spec.lifecycle
}
