module main

import os
import log
import server_lifecycle
import api.mcp.protocol as mcp_protocol
import connection_runtime
import listener_runtime

// A stop ticket retains only the owners and accepted runs it must join.
// Request all tickets before waiting when shutting down multiple Apps.
struct BackgroundNetworkStop {
	internal_admin      &InternalAdminRuntime  @[required]
	mcp                 &mcp_protocol.McpState @[required]
	internal_generation ?u64
	upstream_runs       []&connection_runtime.Run
	bridge_runs         []&connection_runtime.Run
}

fn (mut app App) request_background_network_stop() BackgroundNetworkStop {
	internal_generation := app.lifecycle.internal_admin.request_stop()
	app.protocols.mcp.request_stop()
	upstream_runs := app.websocket.upstream_runs.request_shutdown()
	bridge_runs := app.providers.feishu.background_runs.request_shutdown()
	return BackgroundNetworkStop{
		internal_admin:      app.lifecycle.internal_admin
		mcp:                 &app.protocols.mcp
		internal_generation: internal_generation
		upstream_runs:       upstream_runs
		bridge_runs:         bridge_runs
	}
}

fn (stop &BackgroundNetworkStop) wait() {
	mut internal_admin := stop.internal_admin
	if generation := stop.internal_generation { internal_admin.wait_stopped(generation) }
	for index in 0 .. stop.upstream_runs.len {
		mut owned := stop.upstream_runs[index]
		owned.wait_finished()
	}
	for index in 0 .. stop.bridge_runs.len {
		mut owned := stop.bridge_runs[index]
		owned.wait_finished()
	}
	mut mcp := stop.mcp
	mcp.wait_stopped()
}

// Auxiliary listeners close only after background callbacks have finished using
// DB/cache. All listener generations drain before final shared DB cleanup.
struct AuxiliaryTransportStop {
	cache_owner      &listener_runtime.Owner @[required]
	db_owner         &listener_runtime.Owner @[required]
	cache_generation ?u64
	db_generation    ?u64
}

fn (mut app App) request_auxiliary_shutdown() AuxiliaryTransportStop {
	cache_generation := app.transport.cache.request_shutdown()
	app.mu.@lock()
	db_generation := app.transport.db.request_shutdown()
	app.mu.unlock()
	return AuxiliaryTransportStop{
		cache_owner:      &app.transport.cache.listener_owner
		db_owner:         &app.transport.db.listener_owner
		cache_generation: cache_generation
		db_generation:    db_generation
	}
}

fn (stop &AuxiliaryTransportStop) wait() {
	mut cache_owner := stop.cache_owner
	mut db_owner := stop.db_owner
	if generation := stop.cache_generation { cache_owner.wait_stopped(generation) }
	if generation := stop.db_generation { db_owner.wait_stopped(generation) }
}

fn (mut app App) finish_auxiliary_shutdown(stop AuxiliaryTransportStop) {
	stop.wait()
	$if enable_db ? {
		// Also owns sessions/pools opened by embedded DB calls without a listener,
		// and a generation cancelled before it published its native handle.
		app.db_runtime_cleanup_sessions()
		app.db_runtime_close_pool()
	}
}

fn shutdown_app_runtime(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	app.lifecycle.stop(mut app, runtime_cfg)
}

fn (mut lifecycle ProcessLifecycle) stop(mut app App, runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	shutdown_runtime_bindings([RuntimeShutdownBinding{app: &app, cfg: runtime_cfg}]) or {
		log.error('App shutdown failed: ${err}')
	}
}

struct RuntimeShutdownBinding {
	app &App @[required]
	cfg server_lifecycle.ServerRuntimeConfig
}

// Shared listener bindings start/finalize the actual App once, using the configuration
// that constructed it rather than an alias listener's executor lifecycle.
fn unique_app_runtime_bindings(bindings []RuntimeShutdownBinding) []RuntimeShutdownBinding {
	mut unique := []RuntimeShutdownBinding{}
	for binding in bindings {
		mut found := false
		for index, existing in unique {
			if voidptr(existing.app) != voidptr(binding.app) { continue }
			found = true
			owner_id := binding.app.app_build_cfg.plan_listener_id
			if owner_id != '' && binding.cfg.plan_listener_id == owner_id { unique[index] = binding }
			break
		}
		if !found { unique << binding }
	}
	return unique
}

struct AppTransportStop {
	app &App @[required]
	failure string
}

// A failed ingress retains its App's dependencies. Independent Apps still drain
// and release their own transports; one failure cannot abandon their shutdown.
fn stop_app_transports(mut apps []&App) []AppTransportStop {
	ingress_failures := stop_http_ingresses(mut apps)
	mut results := []AppTransportStop{cap: apps.len}
	mut drained := []&App{cap: apps.len}
	for index, app in apps {
		failure := ingress_failures[index]
		results << AppTransportStop{app: app, failure: failure}
		if failure == '' { drained << app }
	}
	for mut app in drained { app.lifecycle.shutdown.wait_started() }
	mut pending := []BackgroundNetworkStop{cap: drained.len}
	for mut app in drained { pending << app.request_background_network_stop() }
	for stop in pending { stop.wait() }
	mut auxiliary := []AuxiliaryTransportStop{cap: drained.len}
	for mut app in drained { auxiliary << app.request_auxiliary_shutdown() }
	for index, mut app in drained { app.finish_auxiliary_shutdown(auxiliary[index]) }
	return results
}

fn shutdown_runtime_bindings(bindings []RuntimeShutdownBinding) ! {
	mut claimed := []RuntimeShutdownBinding{}
	unique := unique_app_runtime_bindings(bindings)
	for binding in unique {
		mut app := binding.app
		if app.lifecycle.shutdown.claim() {
			claimed << binding
			app.emit('server.stopped', {'pid': '${os.getpid()}'})
		}
	}
	mut apps := claimed.map(it.app)
	stopped := stop_app_transports(mut apps)
	for index, binding in claimed {
		mut app := stopped[index].app
		failure := stopped[index].failure
		if failure == '' { app.finalize_runtime(binding.cfg) }
		app.lifecycle.shutdown.finish(failure)
	}
	// Join every already-claimed owner before reporting aggregate errors.
	mut failures := []string{}
	for binding in unique {
		mut app := binding.app
		app.lifecycle.shutdown.wait_stopped() or { failures << err.msg() }
	}
	if failures.len > 0 { return error(failures.join('\n')) }
}

fn (mut app App) finalize_runtime(runtime_cfg server_lifecycle.ServerRuntimeConfig) {
	log.info('[vhttpd] shutdown_app_runtime: stopping engine runtimes')
	port := app.build_engine_lifecycle_port()
	app.engines.stop(runtime_cfg.executor_plan.lifecycle, port)
	log.info('[vhttpd] shutdown_app_runtime: closing all plugins')
	app.close_all_plugins()
	log.info('[vhttpd] shutdown_app_runtime: stopping all providers')
	app.stop_all_providers()
	log.info('[vhttpd] shutdown_app_runtime: complete')
}
