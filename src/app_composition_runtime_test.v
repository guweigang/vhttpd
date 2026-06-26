module main

import os
import relay
import runtime_plan
import worker

fn test_control_plane_runtime_emits_event_and_updates_stats_without_app() {
	event_log := os.join_path(os.temp_dir(), 'vhttpd_control_plane_runtime_test.ndjson')
	os.rm(event_log) or {}
	defer { os.rm(event_log) or {} }
	mut control := ControlPlaneRuntime{
		event_log: event_log
	}
	control.emit('http.request', {
		'status':        '503'
		'error_class':   'timeout'
		'response_mode': 'stream'
	})
	assert control.http_stats.requests_total == 1
	assert control.http_stats.errors_total == 1
	assert control.http_stats.timeouts_total == 1
	assert control.http_stats.streams_total == 1
	assert os.read_file(event_log)!.contains('"type":"http.request"')
}

fn test_data_plane_runtime_owns_engine_state_without_app() {
	data_plane := DataPlaneRuntime{
		engines: EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					sockets: ['/tmp/engine.sock']
				}
			}
		}
	}
	assert data_plane.engines.primary_socket_count() == 1
}

fn test_data_plane_runtime_owns_relay_state_without_app() {
	relay_runtime := relay.new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'local': runtime_plan.RelayPlan{
				id:   'local'
				mode: 'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'url': 'wss://relay.example.com'
					}
				}
			}
		}
	}) or { panic(err) }
	data_plane := DataPlaneRuntime{
		relay: relay_runtime
	}
	assert data_plane.relay.snapshot().descriptor_count == 1
}

fn test_process_lifecycle_defaults_to_http() {
	lifecycle := ProcessLifecycle{}
	assert lifecycle.started_at_unix == 0
	assert lifecycle.data_plane_scheme == 'http'
}
