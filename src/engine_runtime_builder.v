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

struct AdditionalEngineTargets {
	plan runtime_plan.RuntimePlan
}

fn build_engine_runtime_with_diagnostics_from_plan(cfg config.VhttpdConfig, executor_plan executor.LogicExecutorRuntimePlan, plan runtime_plan.RuntimePlan, listener_id string, routes []RuntimeRouteRule, build_cfg server_lifecycle.AppRuntimeBuildConfig) EngineRuntimeBuildResult {
	additional := build_additional_engine_workers_with_diagnostics_from_plan(cfg, executor_plan,
		plan, listener_id, routes, build_cfg)
	return EngineRuntimeBuildResult{
		runtime:     EngineRuntime{
			primary:    worker_state_from_executor_plan(executor_plan, build_cfg,
				build_cfg.worker_read_timeout_ms, build_cfg.worker_queue_capacity,
				build_cfg.worker_queue_timeout_ms)
			additional: additional.workers
		}
		diagnostics: additional.diagnostics
	}
}

fn build_additional_engine_workers_with_diagnostics_from_plan(cfg config.VhttpdConfig, executor_plan executor.LogicExecutorRuntimePlan, plan runtime_plan.RuntimePlan, listener_id string, routes []RuntimeRouteRule, build_cfg server_lifecycle.AppRuntimeBuildConfig) AdditionalEngineWorkersBuildResult {
	mut add_workers := map[string]&worker.WorkerState{}
	mut diagnostics := []runtime_plan.PlanDiagnostic{}
	targets := AdditionalEngineTargets{
		plan: plan
	}
	for route in routes {
		for target in targets.for_route(listener_id, route) {
			add_worker_for_target(cfg, executor_plan, target, build_cfg, mut add_workers, mut
				diagnostics)
		}
	}
	for target in targets.for_event_pipelines() {
		add_worker_for_target(cfg, executor_plan, target, build_cfg, mut add_workers, mut
			diagnostics)
	}
	return AdditionalEngineWorkersBuildResult{
		workers:     add_workers
		diagnostics: diagnostics
	}
}

fn add_worker_for_target(cfg config.VhttpdConfig, executor_plan executor.LogicExecutorRuntimePlan, target AdditionalEngineBuildTarget, build_cfg server_lifecycle.AppRuntimeBuildConfig, mut add_workers map[string]&worker.WorkerState, mut diagnostics []runtime_plan.PlanDiagnostic) {
	if target.executor_name == '' || target.key in add_workers {
		return
	}
	if target.key == '' && target.executor_name == executor_plan.executor.kind() {
		return
	}
	if target.key == target.executor_name && target.executor_name == executor_plan.executor.kind() {
		return
	}
	sub_plan := executor.LogicExecutorRuntimePlan.resolve_additional_engine_from_plan(cfg,
		target.engine, target.executor_name) or {
		diagnostics << runtime_plan.PlanDiagnostic{
			severity: 'error'
			code:     'additional_engine_runtime_failed'
			path:     'engines.${target.engine.id}'
			message:  'failed to build additional engine ${target.engine.id}: ${err.msg()}'
		}
		return
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
	sub_read_timeout_ms := if target.engine.options.ints['read_timeout_ms'] > 0 {
		target.engine.options.ints['read_timeout_ms']
	} else {
		build_cfg.worker_read_timeout_ms
	}
	mut sub_ws := worker_state_from_executor_plan(sub_plan, build_cfg, sub_read_timeout_ms,
		sub_queue_capacity, sub_queue_timeout_ms)
	add_workers[target.key] = &sub_ws
}

fn (targets AdditionalEngineTargets) for_event_pipelines() []AdditionalEngineBuildTarget {
	mut out := []AdditionalEngineBuildTarget{}
	for pipeline in targets.plan.pipelines {
		if pipeline.ingress.domain != .adapter {
			continue
		}
		adapter := targets.plan.adapters[pipeline.ingress.id] or { continue }
		if adapter.kind != 'event-ingress' {
			continue
		}
		out << targets.from_transform_refs(pipeline.transforms)
	}
	return targets.unique(out)
}

fn (targets AdditionalEngineTargets) for_route(listener_id string, route RuntimeRouteRule) []AdditionalEngineBuildTarget {
	mut out := []AdditionalEngineBuildTarget{}
	if route.executor != '' {
		if route.engine_id != '' {
			if engine := targets.plan.engines[route.engine_id] {
				out << targets.from_engine(route.executor, engine)
			}
		} else if engine := targets.plan.listener_named_engine(listener_id, route.executor) {
			out << targets.from_engine(route.executor, engine)
		}
	}
	for engine_id in route.upload_completed_engine_ids {
		engine := targets.plan.engines[engine_id] or { continue }
		out << targets.from_engine(additional_engine_executor_name(engine), engine)
	}
	out << targets.from_transform_ref_strings(route.transform_refs)
	if targets.plan.source.compatibility && route.upload_completed_engine_ids.len == 0
		&& route.on_completed.trim_space().starts_with('vjsx:') {
		if engine := targets.plan.listener_named_engine(listener_id, 'vjsx') {
			out << targets.from_engine('vjsx', engine)
		}
	}
	return targets.unique(out)
}

fn (targets AdditionalEngineTargets) from_transform_refs(transform_refs []runtime_plan.ResourceRef) []AdditionalEngineBuildTarget {
	return targets.from_transform_ref_strings(transform_refs.map(it.str()))
}

fn (targets AdditionalEngineTargets) from_transform_ref_strings(transform_refs []string) []AdditionalEngineBuildTarget {
	mut out := []AdditionalEngineBuildTarget{}
	for transform_ref in transform_refs {
		ref := runtime_plan.parse_ref(transform_ref) or { continue }
		if ref.domain != .transform {
			continue
		}
		transform := targets.plan.transforms[ref.id] or { continue }
		engine_ref := transform.engine or { continue }
		if engine_ref.domain != .engine {
			continue
		}
		engine := targets.plan.engines[engine_ref.id] or { continue }
		out << targets.from_engine(additional_engine_executor_name(engine), engine)
	}
	return out
}

fn (targets AdditionalEngineTargets) unique(items []AdditionalEngineBuildTarget) []AdditionalEngineBuildTarget {
	mut unique := []AdditionalEngineBuildTarget{}
	mut seen := map[string]bool{}
	for target in items {
		if target.key == '' || seen[target.key] {
			continue
		}
		seen[target.key] = true
		unique << target
	}
	return unique
}

fn (targets AdditionalEngineTargets) from_engine(executor_name string, engine runtime_plan.EnginePlan) AdditionalEngineBuildTarget {
	key := if targets.plan.source.compatibility || engine.id == '' {
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

fn worker_state_from_executor_plan(plan executor.LogicExecutorRuntimePlan, build_cfg server_lifecycle.AppRuntimeBuildConfig, read_timeout_ms int, queue_capacity int, queue_timeout_ms int) worker.WorkerState {
	return worker.WorkerState{
		worker_backend:      worker.WorkerBackendRuntime{
			backend:                worker.PhpWorkerBackend{}
			sockets:                plan.bootstrap.worker_sockets.clone()
			read_timeout_ms:        read_timeout_ms
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
