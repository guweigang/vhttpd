module main

import config
import server_lifecycle
import log
import process_runtime
import provider
import executor
import runtime_plan

struct MultiServerAppBinding {
mut:
	listener server_lifecycle.ListenerRuntimeBinding
	app      &App @[required]
}

type AppRuntimeFactory = fn (provider.ProviderRuntimeSettings, executor.LogicExecutorRuntimePlan, config.VhttpdConfig, runtime_plan.RuntimePlan, server_lifecycle.AppRuntimeBuildConfig) &App

fn build_multi_server_apps(runtime_cfg server_lifecycle.MultiServerRuntimeConfig) []MultiServerAppBinding {
	return build_multi_server_apps_with_factory(runtime_cfg, build_app_runtime)
}

fn build_multi_server_apps_with_factory(runtime_cfg server_lifecycle.MultiServerRuntimeConfig, factory AppRuntimeFactory) []MultiServerAppBinding {
	ids := runtime_cfg.listeners.map(it.runtime_cfg.plan_listener_id)
	mut owners := map[string]&App{}
	// Allocate only real owners. Forward aliases never create a disposable App.
	for listener in runtime_cfg.listeners {
		cfg := listener.runtime_cfg
		if cfg.plan.listener_app_owner_id(cfg.plan_listener_id, ids) != cfg.plan_listener_id {
			continue
		}
		owners[cfg.plan_listener_id] = factory(cfg.provider_settings, cfg.executor_plan,
			listener.site_cfg, cfg.plan, cfg.app_build_cfg)
	}
	mut bindings := []MultiServerAppBinding{cap: runtime_cfg.listeners.len}
	for listener in runtime_cfg.listeners {
		cfg := listener.runtime_cfg
		owner_id := cfg.plan.listener_app_owner_id(cfg.plan_listener_id, ids)
		owner := owners[owner_id] or { panic('missing_app_owner:${owner_id}') }
		bindings << MultiServerAppBinding{ listener: listener, app: owner }
	}
	return bindings
}

fn start_multi_server_apps(mut bindings []MultiServerAppBinding) {
	unique := unique_app_runtime_bindings(bindings.map(RuntimeShutdownBinding{ app: it.app, cfg: it.listener.runtime_cfg }))
	for binding in unique {
		mut app := binding.app
		start_server_runtime(mut app, binding.cfg)
	}
}

fn run_multi_server(args []string, cfg config.VhttpdConfig) ! {
	log.debug('[vhttpd] run_multi_server: resolving multi-server config')
	runtime_cfg := server_lifecycle.resolve_multi_server_runtime_config(args, cfg) or {
		log.error('multi server runtime config resolve failed: ${err}')
		return err
	}
	if runtime_cfg.single_mode {
		log.debug('[vhttpd] run_multi_server: fallback to single mode')
		run_single_server_with_config(cfg, runtime_cfg.listeners[0].runtime_cfg)!
		return
	}
	mut transferred := false
	defer { if !transferred { runtime_cfg.close_untransferred_executors() } }
	if runtime_cfg.listeners.len == 0 {
		msg := 'multi server runtime start failed: no listeners configured'
		log.error(msg)
		return error(msg)
	}
	for binding in runtime_cfg.listeners {
		preflight_server_bind(binding.runtime_cfg) or {
			log.error('[vhttpd] ${err.msg()}')
			return err
		}
	}
	process_runtime.acquire_pid_files(runtime_cfg.listeners.map(it.runtime_cfg.pid_file)) or {
		log.error('[vhttpd] ${err.msg()}')
		return err
	}
	defer { process_runtime.close_pid_files() }
	mut apps := build_multi_server_apps(runtime_cfg)
	transferred = true
	log.debug('[vhttpd] run_multi_server: apps built count=${apps.len}')
	for i in 0 .. apps.len {
		register_active_runtime(apps[i].app, apps[i].listener.runtime_cfg)
	}
	defer {
		if !active_runtime_is_shutting_down() {
			shutdown_multi_server_apps(mut apps)
		}
	}
	start_multi_server_apps(mut apps)
	for i in 0 .. apps.len - 1 {
		mut app_ref := apps[i].app
		spawn serve_server_runtime(mut app_ref, apps[i].listener.runtime_cfg)
	}
	mut last_app := apps[apps.len - 1].app
	serve_server_runtime(mut last_app, apps[apps.len - 1].listener.runtime_cfg)
	wait_for_active_runtime_shutdown()
}

fn shutdown_multi_server_apps(mut bindings []MultiServerAppBinding) {
	shutdown_runtime_bindings(bindings.map(RuntimeShutdownBinding{ app: it.app, cfg: it.listener.runtime_cfg })) or {
		log.error('App shutdown failed: ${err}')
	}
}
