module main

import config
import executor
import runtime_plan
import server_lifecycle
import worker

struct EngineRuntimeBuildResult {
	runtime     EngineRuntime
	diagnostics []runtime_plan.PlanDiagnostic
}

struct AdditionalEngineWorkersBuildResult {
	workers     map[string]&worker.WorkerState
	diagnostics []runtime_plan.PlanDiagnostic
}

struct AdditionalEngineBuildTarget {
	key           string
	executor_name string
	engine        runtime_plan.EnginePlan
}

fn build_engine_runtime_with_diagnostics_from_plan(cfg config.VhttpdConfig, executor_plan executor.LogicExecutorRuntimePlan, plan runtime_plan.RuntimePlan, listener_id string, routes []RuntimeRouteRule, build_cfg server_lifecycle.AppRuntimeBuildConfig) EngineRuntimeBuildResult {
	additional := build_additional_engine_workers_with_diagnostics_from_plan(cfg, executor_plan,
		plan, listener_id, routes, build_cfg)
	return EngineRuntimeBuildResult{
		runtime:     EngineRuntime{
			primary:    worker_state_from_executor_plan(executor_plan, build_cfg,
				build_cfg.worker_queue_capacity, build_cfg.worker_queue_timeout_ms)
			additional: additional.workers
		}
		diagnostics: additional.diagnostics
	}
}

fn build_additional_engine_workers_with_diagnostics_from_plan(cfg config.VhttpdConfig, executor_plan executor.LogicExecutorRuntimePlan, plan runtime_plan.RuntimePlan, listener_id string, routes []RuntimeRouteRule, build_cfg server_lifecycle.AppRuntimeBuildConfig) AdditionalEngineWorkersBuildResult {
	mut add_workers := map[string]&worker.WorkerState{}
	mut diagnostics := []runtime_plan.PlanDiagnostic{}
	for route in routes {
		for target in additional_engine_build_targets_for_route(plan, listener_id, route) {
			if target.executor_name == '' || target.key in add_workers {
				continue
			}
			if target.key == '' && target.executor_name == executor_plan.executor.kind() {
				continue
			}
			if target.key == target.executor_name
				&& target.executor_name == executor_plan.executor.kind() {
				continue
			}
			sub_plan := executor.LogicExecutorRuntimePlan.resolve_additional_engine_from_plan(cfg,
				target.engine, target.executor_name) or {
				diagnostics << runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'additional_engine_runtime_failed'
					path:     'engines.${target.engine.id}'
					message:  'failed to build additional engine ${target.engine.id}: ${err.msg()}'
				}
				continue
			}
			sub_queue_capacity := if target.engine.options.ints['queue_capacity'] > 0 {
				target.engine.options.ints['queue_capacity']
			} else {
				build_cfg.worker_queue_capacity
			}
			sub_queue_timeout_ms := if target.engine.options.ints['queue_timeout_ms'] > 0 {
				target.engine.options.ints['queue_timeout_ms']
			} else {
				build_cfg.worker_queue_timeout_ms
			}
			mut sub_ws := worker_state_from_executor_plan(sub_plan, build_cfg, sub_queue_capacity,
				sub_queue_timeout_ms)
			add_workers[target.key] = &sub_ws
		}
	}
	return AdditionalEngineWorkersBuildResult{
		workers:     add_workers
		diagnostics: diagnostics
	}
}

fn additional_engine_build_targets_for_route(plan runtime_plan.RuntimePlan, listener_id string, route RuntimeRouteRule) []AdditionalEngineBuildTarget {
	mut targets := []AdditionalEngineBuildTarget{}
	if route.executor != '' {
		if route.engine_id != '' {
			if engine := plan.engines[route.engine_id] {
				targets << additional_engine_build_target(plan, route.executor, engine)
			}
		} else if engine := plan.listener_named_engine(listener_id, route.executor) {
			targets << additional_engine_build_target(plan, route.executor, engine)
		}
	}
	for engine_id in route.upload_completed_engine_ids {
		engine := plan.engines[engine_id] or { continue }
		targets << additional_engine_build_target(plan, additional_engine_executor_name(engine),
			engine)
	}
	if plan.source.compatibility && route.upload_completed_engine_ids.len == 0
		&& route.on_completed.trim_space().starts_with('vjsx:') {
		if engine := plan.listener_named_engine(listener_id, 'vjsx') {
			targets << additional_engine_build_target(plan, 'vjsx', engine)
		}
	}
	mut unique := []AdditionalEngineBuildTarget{}
	mut seen := map[string]bool{}
	for target in targets {
		if target.key == '' || seen[target.key] {
			continue
		}
		seen[target.key] = true
		unique << target
	}
	return unique
}

fn additional_engine_build_target(plan runtime_plan.RuntimePlan, executor_name string, engine runtime_plan.EnginePlan) AdditionalEngineBuildTarget {
	key := if plan.source.compatibility || engine.id == '' {
		executor_name
	} else {
		engine.id
	}
	return AdditionalEngineBuildTarget{
		key:           key
		executor_name: executor_name
		engine:        engine
	}
}

fn additional_engine_executor_name(engine runtime_plan.EnginePlan) string {
	if engine.id.contains('/') {
		return engine.id.all_after_last('/')
	}
	if engine.kind != '' {
		return engine.kind
	}
	return engine.id
}

fn worker_state_from_executor_plan(plan executor.LogicExecutorRuntimePlan, build_cfg server_lifecycle.AppRuntimeBuildConfig, queue_capacity int, queue_timeout_ms int) worker.WorkerState {
	return worker.WorkerState{
		worker_backend:      worker.WorkerBackendRuntime{
			backend:                worker.PhpWorkerBackend{}
			sockets:                plan.bootstrap.worker_sockets.clone()
			read_timeout_ms:        build_cfg.worker_read_timeout_ms
			autostart:              plan.bootstrap.worker_autostart
			cmd:                    plan.bootstrap.worker_cmd
			env:                    plan.bootstrap.worker_env.clone()
			workdir:                build_cfg.workdir
			restart_backoff_ms:     build_cfg.worker_restart_backoff_ms
			restart_backoff_max_ms: build_cfg.worker_restart_backoff_max_ms
			max_requests:           build_cfg.worker_max_requests
			queue_capacity:         queue_capacity
			queue_timeout_ms:       queue_timeout_ms
			queue_poll_ms:          10
		}
		worker_backend_mode: plan.worker_backend_mode
		logic_executor:      plan.executor
		lifecycle:           plan.lifecycle.name()
		stream_dispatch:     plan.bootstrap.stream_dispatch
	}
}
