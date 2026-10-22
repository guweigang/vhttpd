module main

import admin
import config
import logging
import log
import relay
import server_lifecycle
import sync
import executor
import runtime_plan
import http_runtime
import process_runtime

struct DataPlaneRuntime {
mut:
	plan runtime_plan.RuntimePlan
	mu   sync.Mutex

	legacy_config config.VhttpdConfig
	app_build_cfg server_lifecycle.AppRuntimeBuildConfig

	transport    TransportRuntimeHub
	websocket    WebSocketRuntime
	upstreams    UpstreamRuntimeRegistry
	relay        relay.Runtime
	protocols    ProtocolRuntimeHub
	providers    ProviderRuntimeHub
	engines      EngineRuntime
	assets       config.AssetsRuntime
	pipelines    PipelineRuntime
	transformers TransformerRuntimeHub
	replacement  RuntimePlanReplacementRuntime
}

struct ControlPlaneRuntime {
mut:
	mu                sync.Mutex
	admin             admin.AdminState
	http_stats        HttpStats
	http_observations HttpObservations
	event_log         string
}

struct ProcessLifecycle {
mut:
	shutdown                 &process_runtime.ShutdownOwner = &process_runtime.ShutdownOwner{}
	http_admission_installed bool
	http                     &http_runtime.Owner   = &http_runtime.Owner{}
	admin_http               &http_runtime.Owner   = &http_runtime.Owner{}
	internal_admin           &InternalAdminRuntime = &InternalAdminRuntime{}
	started_at_unix          i64
	data_plane_scheme        string = 'http'
}

fn (mut control ControlPlaneRuntime) emit(kind string, fields map[string]string) {
	control.mu.@lock()
	if kind == 'http.request' {
		control.http_stats.inc_requests()
		status := (fields['status'] or { '0' }).int()
		if status >= 400 {
			control.http_stats.inc_errors()
		}
		if (fields['error_class'] or { '' }) == 'timeout' {
			control.http_stats.inc_timeouts()
		}
		if (fields['response_mode'] or { '' }) == 'stream' {
			control.http_stats.inc_streams()
		}
	}
	if kind.starts_with('admin.') {
		control.http_stats.inc_admin_actions()
	}
	path := control.event_log
	if path == '' {
		control.mu.unlock()
		return
	}
	logging.append_line(path, logging.RuntimeLogger.event_json(kind, fields)) or {
		control.mu.unlock()
		log.error('[vhttpd] event_log append failed path=${path}: ${err.msg()}')
		return
	}
	control.mu.unlock()
}

fn (mut control ControlPlaneRuntime) stats_snapshot(ctx admin.RuntimeContext) executor.AdminRuntimeStats {
	control.mu.@lock()
	defer { control.mu.unlock() }
	return control.admin.stats_snapshot(ctx)
}

fn (mut control ControlPlaneRuntime) runtime_snapshot(ctx admin.RuntimeContext) executor.AdminRuntimeSummary {
	return control.admin.runtime_snapshot(ctx)
}
