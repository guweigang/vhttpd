module main

import admin
import config
import executor
import json
import os
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

fn test_internal_admin_runtime_plan_replacement_previews_diff_from_config() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_preview_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	current_file := os.join_path(temp_dir, 'current.toml')
	config_file := os.join_path(temp_dir, 'next.toml')
	current_text := '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[engines.app]
kind = "php-worker"
entry = "/tmp/app.php"

[engines.admin]
kind = "vjsx"
entry = "/tmp/admin.mts"

[adapters.app]
kind = "http-handler"
engine = "engine:app"

[adapters.admin]
kind = "http-handler"
engine = "engine:admin"

[[pipelines]]
id = "site/app"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"

[[pipelines]]
id = "site/admin"
ingress = "listener:web"
match.paths = ["/admin"]
egress = "adapter:admin"
'
	os.write_file(current_file, current_text) or { panic(err) }
	os.write_file(config_file, current_text.replace('[engines.app]\nkind = "php-worker"\nentry = "/tmp/app.php"',
		'[engines.app]\nkind = "php-worker"\nentry = "/tmp/app.php"\nqueue_capacity = 128')) or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut app := App{
		plan: config.load_runtime_plan_file(current_file) or { panic(err) }
	}
	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/runtime/plan/replacement'
		query:  {
			'config': config_file
		}
	})
	assert resp.status == 200
	preview := json.decode(RuntimePlanReplacementPreview, resp.body) or { panic(err) }
	assert !preview.allowed
	assert preview.strategy == 'engine_drain_required'
	assert preview.actions.any(it.kind == 'drain_engines' && it.targets == ['app'])
	assert preview.config_path == config_file
	assert preview.drain_engines == ['app']
	assert preview.changed_pipelines == ['site/app']
	assert preview.unchanged_pipelines == ['site/admin']
	assert preview.current_schema_version == 2
	assert preview.next_schema_version == 2
	state_resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/runtime/plan/replacement/state'
	})
	state := json.decode(RuntimePlanReplacementRuntimeSnapshot, state_resp.body) or { panic(err) }
	assert state.previews_total == 1
	assert state.last_preview.kind == 'preview'
	assert state.last_preview.status == 'previewed'
	assert state.last_preview.strategy == 'engine_drain_required'
	assert state.last_preview.config_path == config_file
	assert state.last_preview.changed_pipelines == ['site/app']
}

fn test_internal_admin_runtime_plan_replacement_apply_updates_lightweight_routes() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_apply_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	current_file := os.join_path(temp_dir, 'current.toml')
	config_file := os.join_path(temp_dir, 'next.toml')
	current_text := '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[adapters.hello]
kind = "fixed-response"
options.status = "200"
options.body = "old"

[[pipelines]]
id = "site/hello"
ingress = "listener:web"
match.paths = ["/hello"]
egress = "adapter:hello"
'
	os.write_file(current_file, current_text) or { panic(err) }
	os.write_file(config_file, current_text.replace('options.body = "old"', 'options.body = "new"')) or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		plan:         current_plan
		protocols:    ProtocolRuntimeHub{
			runtime_plan_json: json.encode(current_plan)
		}
		pipelines:    PipelineRuntime.new(current_plan, 'web', runtime_routes_from_plan(current_plan,
			'web'), '', '', map[string]string{}, map[string]&worker.WorkerState{})
		transformers: TransformerRuntimeHub.from_plan(current_plan)
	}
	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/apply'
		query:  {
			'config': config_file
		}
	})
	assert resp.status == 200
	result := json.decode(RuntimePlanReplacementApplyResult, resp.body) or { panic(err) }
	assert result.applied
	assert result.status == 'applied'
	assert result.strategy == 'lightweight'
	assert result.preview.actions[0].kind == 'swap_lightweight_runtime'
	assert app.protocols.runtime_plan_json.contains('"body":"new"')
	assert app.pipelines.http.rules.len == 1
	assert app.pipelines.http.rules[0].body == 'new'
	assert app.plan.adapters['hello'].options.strings['body'] == 'new'
	state := app.runtime_plan_replacement_snapshot()
	assert state.applies_total == 1
	assert state.applied_total == 1
	assert state.rejected_total == 0
	assert state.last_apply.kind == 'apply'
	assert state.last_apply.status == 'applied'
	assert state.last_apply.strategy == 'lightweight'
	assert state.last_apply.applied
	assert state.last_apply.actions[0].kind == 'swap_lightweight_runtime'
	assert state.last_apply.changed_pipelines == ['site/hello']
}

fn test_internal_admin_runtime_plan_replacement_apply_rejects_engine_drain() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_apply_reject_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	current_file := os.join_path(temp_dir, 'current.toml')
	config_file := os.join_path(temp_dir, 'next.toml')
	current_text := '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[engines.app]
kind = "php-worker"
entry = "/tmp/app.php"

[adapters.app]
kind = "http-handler"
engine = "engine:app"

[[pipelines]]
id = "site/app"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"
'
	os.write_file(current_file, current_text) or { panic(err) }
	os.write_file(config_file, current_text.replace('entry = "/tmp/app.php"',
		'entry = "/tmp/app-next.php"')) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		plan:      current_plan
		protocols: ProtocolRuntimeHub{
			runtime_plan_json: json.encode(current_plan)
		}
		pipelines: PipelineRuntime.new(current_plan, 'web', runtime_routes_from_plan(current_plan,
			'web'), '', '', map[string]string{}, map[string]&worker.WorkerState{})
	}
	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/apply'
		query:  {
			'config': config_file
		}
	})
	assert resp.status == 409
	result := json.decode(RuntimePlanReplacementApplyResult, resp.body) or { panic(err) }
	assert !result.applied
	assert result.strategy == 'engine_drain_required'
	assert result.error == 'runtime_plan_replacement_requires_engine_drain'
	assert app.plan.engines['app'].options.strings['entry'] == '/tmp/app.php'
	state := app.runtime_plan_replacement_snapshot()
	assert state.applies_total == 1
	assert state.applied_total == 0
	assert state.rejected_total == 1
	assert state.last_apply.status == 'rejected'
	assert state.last_apply.strategy == 'engine_drain_required'
	assert state.last_apply.error == 'runtime_plan_replacement_requires_engine_drain'
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
