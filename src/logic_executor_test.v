module main

import admin
import executor
import json
import relay
import worker

fn test_disabled_logic_executor_identity() {
	disabled_executor := executor.DisabledLogicExecutor{}
	assert disabled_executor.model() == .worker
	assert disabled_executor.kind() == 'none'
	assert disabled_executor.provider() == 'none'
}

fn test_socket_worker_executor_identity() {
	socket_executor := executor.SocketWorkerExecutor{}
	assert socket_executor.model() == .worker
	assert socket_executor.kind() == 'php'
	assert socket_executor.provider() == 'php-worker'
}

fn test_php_cgi_executor_identity() {
	cgi_executor := executor.PhpCgiExecutor{}
	assert cgi_executor.model() == .worker
	assert cgi_executor.kind() == 'php-cgi'
	assert cgi_executor.provider() == 'php-cgi'
}

fn test_app_facade_returns_env_for_named_executor_pool() {
	mut app := App{
		engines: EngineRuntime{
			primary:    worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					env: {
						'VPHP_WP_ROOT': '/main'
					}
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
			additional: {
				'php-cgi': &worker.WorkerState{
					worker_backend: worker.WorkerBackendRuntime{
						env: {
							'VPHP_WP_ROOT': '/cgi'
						}
					}
					logic_executor: executor.PhpCgiExecutor{}
				}
			}
		}
	}
	facade := app.as_facade()
	assert facade.worker_env_for_kind('php') == {
		'VPHP_WP_ROOT': '/main'
	}
	assert facade.worker_env_for_kind('php-cgi') == {
		'VPHP_WP_ROOT': '/cgi'
	}
}

fn test_logic_executor_can_hold_inproc_vjsx_executor() {
	mut logic_executor := executor.LogicExecutor(new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count: 1
	}))
	assert logic_executor.model() == .embedded
	assert logic_executor.kind() == 'vjsx'
	assert logic_executor.provider() == 'vjsx'
}

fn test_admin_runtime_snapshot_exposes_embedded_logic_executor_identity() {
	mut app := App{
		engines: EngineRuntime{
			primary: worker.WorkerState{
				worker_backend_mode: .disabled
				lifecycle:           'embedded_host'
				logic_executor:      new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
					thread_count:    1
					module_root:     '/tmp/demo'
					build_root:      '/tmp/demo-build'
					signature_root:  '/tmp/demo'
					runtime_profile: 'node'
					enable_fs:       true
				})
			}
		}
	}
	snapshot := app.admin_runtime_snapshot()
	assert snapshot.logic_executor.kind == 'vjsx'
	assert snapshot.logic_executor.lifecycle == 'embedded_host'
	assert snapshot.logic_executor.model == 'embedded'
	assert snapshot.logic_executor.provider == 'vjsx'
	assert snapshot.worker_pool.backend_mode == 'disabled'
	assert snapshot.logic_executor.details.kind == 'vjsx'
	assert snapshot.logic_executor.details.model == 'embedded'
	assert snapshot.logic_executor.details.runtime_profile == 'node'
	assert snapshot.logic_executor.details.lane_count == 1
	assert snapshot.logic_executor.details.module_root == '/tmp/demo'
	assert snapshot.logic_executor.details.build_root == '/tmp/demo-build'
	assert snapshot.logic_executor.details.enable_fs
}

fn test_internal_admin_runtime_exposes_worker_logic_executor_identity() {
	mut app := App{
		engines: EngineRuntime{
			primary: worker.WorkerState{
				worker_backend_mode: .required
				lifecycle:           'php_worker_host'
				logic_executor:      executor.SocketWorkerExecutor{}
			}
		}
	}
	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/runtime'
	})
	assert resp.status == 200
	snapshot := json.decode(executor.AdminRuntimeSummary, resp.body) or { panic(err) }
	assert snapshot.logic_executor.kind == 'php'
	assert snapshot.logic_executor.lifecycle == 'php_worker_host'
	assert snapshot.logic_executor.model == 'worker'
	assert snapshot.logic_executor.provider == 'php-worker'
	assert snapshot.worker_pool.backend_mode == 'required'
	assert snapshot.logic_executor.details.kind == 'php'
	assert snapshot.logic_executor.details.model == 'worker'
	assert snapshot.logic_executor.details.runtime_profile == ''
	assert snapshot.logic_executor.details.lane_count == 0
}

fn test_admin_runtime_snapshot_exposes_relay_summary() {
	mut app := App{
		relay: relay.empty_runtime()
	}
	app.relay.register_carrier('edge', 'carrier_edge') or { panic(err) }
	app.relay.channels.open_channel(relay.RelayChannel{
		id:       'chan_1'
		node_id:  'node_1'
		route:    'site/main'
		trace_id: 'trace_1'
	}) or { panic(err) }
	app.relay.channels.enqueue('chan_1', relay.new_frame(.data, 'frm_1', 'trace_1')) or {
		panic(err)
	}
	snapshot := app.admin_runtime_snapshot()
	assert snapshot.relay.channel_count == 1
	assert snapshot.relay.open_channels == 1
	assert snapshot.relay.carrier_count == 1
	assert snapshot.relay.pending_frames == 1
	assert snapshot.relay.carriers[0].relay_id == 'edge'
	assert snapshot.relay.carriers[0].carrier_id == 'carrier_edge'
	assert snapshot.relay.channels[0].trace_id == 'trace_1'
}
