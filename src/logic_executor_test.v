module main

import admin
import config
import executor
import json
import os
import relay
import runtime_plan
import server_lifecycle
import worker
import upstream.transport

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

fn test_plan_engine_ids_resolve_to_worker_pools() {
	app := App{
		engines: EngineRuntime{
			primary:    worker.WorkerState{
				logic_executor: executor.SocketWorkerExecutor{}
			}
			additional: {
				'php-cgi': &worker.WorkerState{
					logic_executor: executor.PhpCgiExecutor{}
				}
			}
		}
	}

	assert (app.resolve_engine_worker_pool('php') or { panic(err) }) == ''
	assert (app.resolve_engine_worker_pool('site/php') or { panic(err) }) == ''
	assert (app.resolve_engine_worker_pool('php-cgi') or { panic(err) }) == 'php-cgi'
	assert (app.resolve_engine_worker_pool('site/php-cgi') or { panic(err) }) == 'php-cgi'
}

fn test_plan_engine_without_worker_pool_does_not_resolve_to_primary() {
	app := App{
		plan:      runtime_plan.RuntimePlan{
			engines:   {
				'php':           runtime_plan.EnginePlan{
					id:   'php'
					kind: 'php-worker'
				}
				'upload-events': runtime_plan.EnginePlan{
					id:   'upload-events'
					kind: 'vjsx'
				}
			}
			adapters:  {
				'wordpress-worker': runtime_plan.AdapterPlan{
					id:     'wordpress-worker'
					kind:   'http-handler'
					engine: runtime_plan.ResourceRef{
						domain: .engine
						id:     'php'
					}
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'wordpress.front-page'
					ingress: runtime_plan.ResourceRef{
						domain: .listener
						id:     'web'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .adapter
						id:     'wordpress-worker'
					}
				},
			]
		}
		pipelines: PipelineRuntime{
			http: HttpRoutingRuntime{
				listener_id: 'web'
			}
		}
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: executor.SocketWorkerExecutor{}
			}
		}
	}

	assert (app.resolve_engine_worker_pool('php') or { panic(err) }) == ''
	if _ := app.resolve_engine_worker_pool('upload-events') {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_replacement_engine_has_no_worker_pool:upload-events'
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

fn test_internal_admin_runtime_plan_replacement_apply_starts_engine_drain() {
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
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path:       '/tmp/app.sock'
							inflight_requests: 1
						},
					]
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
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
	assert resp.status == 202
	result := json.decode(RuntimePlanReplacementApplyResult, resp.body) or { panic(err) }
	assert !result.applied
	assert result.status == 'draining'
	assert result.strategy == 'engine_drain_required'
	assert result.error == ''
	assert result.drains.len == 1
	assert result.drains[0].worker_count == 1
	assert result.drains[0].inflight_requests == 1
	assert app.plan.engines['app'].options.strings['entry'] == '/tmp/app.php'
	assert app.engines.primary.worker_backend.managed_workers[0].draining
	state := app.runtime_plan_replacement_snapshot()
	assert state.applies_total == 1
	assert state.applied_total == 0
	assert state.draining_total == 1
	assert state.rejected_total == 0
	assert state.pending.active
	assert state.pending.config_path == config_file
	assert state.pending.config_hash == result.config_hash
	assert state.pending.config_hash.len == 64
	assert !state.pending.ready
	assert state.pending.created_at_unix > 0
	assert state.pending.updated_at_unix >= state.pending.created_at_unix
	assert state.pending.drain_statuses.len == 1
	assert state.last_apply.status == 'draining'
	assert state.last_apply.strategy == 'engine_drain_required'
	assert state.last_apply.error == ''
	assert state.last_apply.drain_statuses.len == 1
	assert state.last_apply.drain_statuses[0].inflight_requests == 1
}

fn test_internal_admin_runtime_plan_replacement_apply_rejects_engine_without_worker_pool() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_apply_embedded_engine_test')
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

[engines.upload-events]
kind = "vjsx"
entry = "/tmp/upload.mts"
thread_count = 1

[adapters.app]
kind = "http-handler"
engine = "engine:app"

[transforms.upload-completed]
kind = "vjsx"
engine = "engine:upload-events"
handler = "upload.completed"

[[pipelines]]
id = "site/app"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"

[[pipelines]]
id = "upload.completed"
ingress = "listener:web"
match.metadata = { event = "upload.completed" }
transforms = ["transform:upload-completed"]
egress = "terminal:accepted"
'
	os.write_file(current_file, current_text) or { panic(err) }
	os.write_file(config_file, current_text.replace('thread_count = 1', 'thread_count = 2')) or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	current_plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := App{
		plan:      current_plan
		protocols: ProtocolRuntimeHub{
			runtime_plan_json: json.encode(current_plan)
		}
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: executor.SocketWorkerExecutor{}
			}
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
	assert result.status == 'rejected'
	assert result.strategy == 'engine_drain_required'
	assert result.error == 'runtime_plan_replacement_engine_has_no_worker_pool:upload-events'
	assert result.preview.drain_engines == ['upload-events']
	assert result.preview.changed_pipelines == ['upload.completed']
	assert result.drains.len == 0
	state := app.runtime_plan_replacement_snapshot()
	assert state.applies_total == 1
	assert state.applied_total == 0
	assert state.draining_total == 0
	assert state.rejected_total == 1
	assert !state.pending.active
	assert state.last_apply.status == 'rejected'
	assert state.last_apply.error == 'runtime_plan_replacement_engine_has_no_worker_pool:upload-events'
	assert state.last_apply.drain_engines == ['upload-events']
	assert state.last_apply.changed_pipelines == ['upload.completed']
}

fn test_runtime_plan_replacement_snapshot_exposes_pending_refresh_error() {
	mut app := App{
		plan:        runtime_plan.RuntimePlan{
			engines:   {
				'php':           runtime_plan.EnginePlan{
					id:   'php'
					kind: 'php-worker'
				}
				'upload-events': runtime_plan.EnginePlan{
					id:   'upload-events'
					kind: 'vjsx'
				}
			}
			adapters:  {
				'wordpress-worker': runtime_plan.AdapterPlan{
					id:     'wordpress-worker'
					kind:   'http-handler'
					engine: runtime_plan.ResourceRef{
						domain: .engine
						id:     'php'
					}
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'wordpress.front-page'
					ingress: runtime_plan.ResourceRef{
						domain: .listener
						id:     'web'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .adapter
						id:     'wordpress-worker'
					}
				},
			]
		}
		pipelines:   PipelineRuntime{
			http: HttpRoutingRuntime{
				listener_id: 'web'
			}
		}
		engines:     EngineRuntime{
			primary: worker.WorkerState{
				logic_executor: executor.SocketWorkerExecutor{}
			}
		}
		replacement: RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:        true
				config_path:   '/tmp/next.toml'
				strategy:      'engine_drain_required'
				drain_engines: ['upload-events']
			}
		}
	}

	state := app.runtime_plan_replacement_snapshot()
	assert state.applies_total == 0
	assert state.pending.active
	assert state.pending.config_path == '/tmp/next.toml'
	assert state.pending.drain_engines == ['upload-events']
	assert state.pending.refresh_error == 'runtime_plan_replacement_engine_has_no_worker_pool:upload-events'
}

fn test_runtime_plan_replacement_snapshot_refreshes_pending_drain_ready() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_refresh_drain_test')
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
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path:       '/tmp/app-refresh.sock'
							inflight_requests: 1
						},
					]
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
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
	assert resp.status == 202
	result := json.decode(RuntimePlanReplacementApplyResult, resp.body) or { panic(err) }
	assert result.status == 'draining'

	app.engines.request_finished(EngineLifecyclePort{}, '/tmp/app-refresh.sock')
	state := app.runtime_plan_replacement_snapshot()

	assert state.pending.active
	assert state.pending.ready
	assert state.pending.config_hash == result.config_hash
	assert state.pending.config_hash.len == 64
	assert state.pending.created_at_unix > 0
	assert state.pending.updated_at_unix >= state.pending.created_at_unix
	assert state.pending.drain_statuses.len == 1
	assert state.pending.drain_statuses[0].ready_count == 1
	assert state.pending.drain_statuses[0].inflight_requests == 0
}

fn test_internal_admin_runtime_plan_replacement_apply_rejects_when_pending_exists() {
	mut app := App{
		replacement: RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:              true
				config_path:         '/tmp/current-pending.toml'
				strategy:            'engine_drain_required'
				ready:               false
				drain_engines:       ['app']
				changed_pipelines:   ['site/app']
				unchanged_pipelines: ['site/admin']
				next_schema_version: 2
			}
		}
	}

	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/apply'
		query:  {
			'config': '/tmp/next.toml'
		}
	})
	result := json.decode(RuntimePlanReplacementApplyResult, resp.body) or { panic(err) }

	assert resp.status == 409
	assert !result.applied
	assert result.status == 'rejected'
	assert result.error == 'runtime_plan_replacement_pending_exists'
	assert result.config_path == '/tmp/next.toml'
	assert result.strategy == 'engine_drain_required'
	assert result.preview.config_path == '/tmp/current-pending.toml'
	assert result.preview.drain_engines == ['app']
	assert result.preview.changed_pipelines == ['site/app']
	assert result.preview.unchanged_pipelines == ['site/admin']
	assert result.preview.next_schema_version == 2
	state := app.runtime_plan_replacement_snapshot()
	assert state.applies_total == 1
	assert state.rejected_total == 1
	assert state.pending.active
	assert state.pending.config_path == '/tmp/current-pending.toml'
	assert state.last_apply.config_path == '/tmp/next.toml'
	assert state.last_apply.error == 'runtime_plan_replacement_pending_exists'
}

fn test_internal_admin_runtime_plan_replacement_finalize_requires_pending() {
	mut app := App{}

	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/finalize'
	})
	result := json.decode(RuntimePlanReplacementFinalizeResult, resp.body) or { panic(err) }

	assert resp.status == 409
	assert !result.applied
	assert result.status == 'rejected'
	assert result.error == 'runtime_plan_replacement_no_pending'
	state := app.runtime_plan_replacement_snapshot()
	assert state.finalizes_total == 1
	assert state.finalized_total == 0
	assert state.last_finalize.kind == 'finalize'
	assert state.last_finalize.status == 'rejected'
	assert state.last_finalize.error == 'runtime_plan_replacement_no_pending'
}

fn test_internal_admin_runtime_plan_replacement_cancel_requires_pending() {
	mut app := App{}

	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/cancel'
	})
	result := json.decode(RuntimePlanReplacementCancelResult, resp.body) or { panic(err) }

	assert resp.status == 409
	assert !result.cancelled
	assert result.status == 'rejected'
	assert result.error == 'runtime_plan_replacement_no_pending'
	state := app.runtime_plan_replacement_snapshot()
	assert state.cancels_total == 1
	assert state.cancelled_total == 0
	assert state.last_cancel.kind == 'cancel'
	assert state.last_cancel.status == 'rejected'
	assert state.last_cancel.error == 'runtime_plan_replacement_no_pending'
}

fn test_internal_admin_runtime_plan_replacement_cancel_resumes_pending_workers() {
	mut app := App{
		replacement: RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:        true
				config_path:   '/tmp/next.toml'
				strategy:      'engine_drain_required'
				ready:         true
				drain_engines: ['app']
			}
		}
		engines:     EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path:       '/tmp/app-cancel.sock'
							inflight_requests: 1
							draining:          true
						},
					]
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
		}
	}

	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/cancel'
	})
	result := json.decode(RuntimePlanReplacementCancelResult, resp.body) or { panic(err) }

	assert resp.status == 200
	assert result.cancelled
	assert result.status == 'cancelled'
	assert result.resumed.len == 1
	assert result.resumed[0].changed
	assert !app.replacement.pending.active
	assert !app.engines.primary.worker_backend.managed_workers[0].draining
	state := app.runtime_plan_replacement_snapshot()
	assert state.cancels_total == 1
	assert state.cancelled_total == 1
	assert state.last_cancel.status == 'cancelled'
	assert state.last_cancel.drain_statuses.len == 1
	assert state.last_cancel.drain_statuses[0].changed
}

fn test_internal_admin_runtime_plan_replacement_finalize_waits_for_drain() {
	mut app := App{
		replacement: RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:        true
				config_path:   '/tmp/next.toml'
				strategy:      'engine_drain_required'
				ready:         false
				drain_engines: ['app']
			}
		}
		engines:     EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path:       '/tmp/app-wait.sock'
							inflight_requests: 1
							draining:          true
						},
					]
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
		}
	}

	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/finalize'
	})
	result := json.decode(RuntimePlanReplacementFinalizeResult, resp.body) or { panic(err) }

	assert resp.status == 409
	assert !result.applied
	assert result.status == 'waiting_for_drain'
	assert result.error == 'runtime_plan_replacement_drain_not_ready'
	assert result.pending.drain_statuses[0].inflight_requests == 1
	state := app.runtime_plan_replacement_snapshot()
	assert state.finalizes_total == 1
	assert state.finalized_total == 0
	assert state.last_finalize.status == 'waiting_for_drain'
	assert state.last_finalize.drain_statuses[0].inflight_requests == 1
}

fn test_internal_admin_runtime_plan_replacement_finalize_applies_ready_engine_runtime() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_finalize_engine_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'next.toml')
	next_entry := os.join_path(temp_dir, 'app-next.php')
	os.write_file(next_entry, '<?php echo "next";') or { panic(err) }
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[engines.app]
kind = "php-worker"
entry = "${next_entry}"
autostart = false
socket = "/tmp/vhttpd-finalize-external.sock"

[adapters.app]
kind = "http-handler"
engine = "engine:app"

[[pipelines]]
id = "site/app"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut app := App{
		legacy_config: config.default_vhttpd_config()
		app_build_cfg: server_lifecycle.AppRuntimeBuildConfig{
			plan_listener_id:        'web'
			worker_queue_capacity:   8
			worker_queue_timeout_ms: 25
			workdir:                 temp_dir
		}
		replacement:   RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:        true
				config_path:   config_file
				strategy:      'engine_drain_required'
				ready:         true
				drain_engines: ['app']
			}
		}
		pipelines:     PipelineRuntime{
			http: HttpRoutingRuntime{
				listener_id: 'web'
			}
		}
		engines:       EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path: '/tmp/app-ready-finalize.sock'
							draining:    true
						},
					]
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
		}
	}

	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/finalize'
	})
	result := json.decode(RuntimePlanReplacementFinalizeResult, resp.body) or { panic(err) }

	assert resp.status == 200
	assert result.applied
	assert result.status == 'applied'
	assert result.error == ''
	assert result.pending.ready
	assert result.pending.drain_statuses[0].ready_count == 1
	assert app.plan.engines['app'].options.strings['entry'] == next_entry
	assert app.engines.primary.worker_backend.cmd.contains(next_entry)
	assert app.engines.primary.worker_backend.queue_capacity == 8
	assert !app.replacement.pending.active
	state := app.runtime_plan_replacement_snapshot()
	assert state.finalizes_total == 1
	assert state.finalized_total == 1
	assert state.applied_total == 1
	assert state.last_finalize.status == 'applied'
	assert state.last_finalize.applied
	assert state.last_finalize.drain_statuses[0].ready_count == 1
}

fn test_internal_admin_runtime_plan_replacement_finalize_rejects_changed_pending_config() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_finalize_changed_config_test')
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
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path: '/tmp/app-changed-config.sock'
						},
					]
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
		}
		pipelines: PipelineRuntime.new(current_plan, 'web', runtime_routes_from_plan(current_plan,
			'web'), '', '', map[string]string{}, map[string]&worker.WorkerState{})
	}
	apply_resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/apply'
		query:  {
			'config': config_file
		}
	})
	apply_result := json.decode(RuntimePlanReplacementApplyResult, apply_resp.body) or {
		panic(err)
	}
	assert apply_resp.status == 202
	assert apply_result.status == 'drain_ready'
	assert apply_result.config_hash.len == 64

	os.write_file(config_file, current_text.replace('entry = "/tmp/app.php"',
		'entry = "/tmp/app-mutated.php"')) or { panic(err) }
	finalize_resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/runtime/plan/replacement/finalize'
	})
	finalize_result := json.decode(RuntimePlanReplacementFinalizeResult, finalize_resp.body) or {
		panic(err)
	}

	assert finalize_resp.status == 409
	assert !finalize_result.applied
	assert finalize_result.status == 'rejected'
	assert finalize_result.error == 'runtime_plan_replacement_config_changed'
	assert app.replacement.pending.active
	assert app.plan.engines['app'].options.strings['entry'] == '/tmp/app.php'
	state := app.runtime_plan_replacement_snapshot()
	assert state.finalizes_total == 1
	assert state.finalized_total == 0
	assert state.last_finalize.error == 'runtime_plan_replacement_config_changed'
}

fn test_runtime_plan_replacement_prepares_next_engine_runtime() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_prepare_engine_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'next.toml')
	next_entry := os.join_path(temp_dir, 'app-next.php')
	os.write_file(next_entry, '<?php echo "next";') or { panic(err) }
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[engines.app]
kind = "php-worker"
entry = "${next_entry}"

[adapters.app]
kind = "http-handler"
engine = "engine:app"

[[pipelines]]
id = "site/app"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut cfg := config.default_vhttpd_config()
	mut app := App{
		legacy_config: cfg
		app_build_cfg: server_lifecycle.AppRuntimeBuildConfig{
			plan_listener_id:        'web'
			worker_queue_capacity:   8
			worker_queue_timeout_ms: 25
			workdir:                 temp_dir
		}
		pipelines:     PipelineRuntime{
			http: HttpRoutingRuntime{
				listener_id: 'web'
			}
		}
	}
	pending := RuntimePlanReplacementPendingSnapshot{
		active:      true
		config_path: config_file
		ready:       true
		strategy:    'engine_drain_required'
	}

	prepared := app.prepare_runtime_plan_replacement_runtime(pending) or { panic(err) }

	assert prepared.listener == 'web'
	assert prepared.plan.engines['app'].options.strings['entry'] == next_entry
	assert prepared.engines.primary.logic_executor.kind() == 'php'
	assert prepared.engines.primary.worker_backend.cmd.contains(next_entry)
	assert prepared.engines.primary.worker_backend.queue_capacity == 8
	assert prepared.routes.len == 1
}

fn test_internal_admin_runtime_plan_replacement_reports_drain_ready() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_plan_replacement_drain_ready_test')
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
		engines:   EngineRuntime{
			primary: worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path: '/tmp/app-ready.sock'
						},
					]
				}
				logic_executor: executor.SocketWorkerExecutor{}
			}
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
	assert resp.status == 202
	result := json.decode(RuntimePlanReplacementApplyResult, resp.body) or { panic(err) }
	assert !result.applied
	assert result.status == 'drain_ready'
	assert result.drains[0].ready_count == 1
	assert app.plan.engines['app'].options.strings['entry'] == '/tmp/app.php'
	state := app.runtime_plan_replacement_snapshot()
	assert state.pending.active
	assert state.pending.ready
	assert state.pending.config_hash == result.config_hash
	assert state.pending.config_hash.len == 64
	assert state.pending.created_at_unix > 0
	assert state.pending.updated_at_unix >= state.pending.created_at_unix
	assert state.pending.drain_statuses[0].ready_count == 1
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
