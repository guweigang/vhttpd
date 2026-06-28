module main

import admin
import config
import json
import os
import relay
import sync
import time
import executor
import runtime_plan

struct DataPlaneRuntime {
mut:
	plan runtime_plan.RuntimePlan
	mu   sync.Mutex

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
	mu         sync.Mutex
	admin      admin.AdminState
	http_stats HttpStats
	event_log  string
}

struct ProcessLifecycle {
mut:
	started_at_unix   i64
	data_plane_scheme string = 'http'
}

fn (mut control ControlPlaneRuntime) emit(kind string, fields map[string]string) {
	control.mu.@lock()
	defer { control.mu.unlock() }
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
	mut row := map[string]string{}
	row['type'] = kind
	row['ts'] = '${time.now().unix()}'
	for key, value in fields {
		row[key] = value
	}
	mut file := os.open_append(control.event_log) or { return }
	defer { file.close() }
	file.writeln(json.encode(row)) or {}
}

fn (mut control ControlPlaneRuntime) stats_snapshot(ctx admin.RuntimeContext) executor.AdminRuntimeStats {
	control.mu.@lock()
	defer { control.mu.unlock() }
	return control.admin.stats_snapshot(ctx)
}

fn (mut control ControlPlaneRuntime) runtime_snapshot(ctx admin.RuntimeContext) executor.AdminRuntimeSummary {
	return control.admin.runtime_snapshot(ctx)
}
