module main

import config
import executor
import os
import provider
import runtime_plan
import server_lifecycle
import sync
import time
import worker

@[heap]
struct MultiAppProbe {
mut:
	mu   sync.Mutex
	rows []string
	apps []&App
}

fn (mut p MultiAppProbe) record(row string) {
	p.mu.@lock()
	p.rows << row
	p.mu.unlock()
}

struct MultiAppExecutor {
	executor.DisabledLogicExecutor
	id    string
	probe &MultiAppProbe @[required]
}

fn (_ MultiAppExecutor) kind() string { return 'none' }

fn (e MultiAppExecutor) warmup(mut _ executor.AppFacade) ! {
	mut p := e.probe
	p.record('warmup:${e.id}')
}

fn (e MultiAppExecutor) close() {
	mut p := e.probe
	p.record('close:${e.id}')
}

fn multi_app_plan() runtime_plan.RuntimePlan {
	return runtime_plan.RuntimePlan{
		listeners: {
			'a_relay': runtime_plan.ListenerPlan{ id: 'a_relay', protocol: 'websocket' }
			'b_relay': runtime_plan.ListenerPlan{ id: 'b_relay', protocol: 'websocket' }
			'c_solo':  runtime_plan.ListenerPlan{ id: 'c_solo', protocol: 'websocket' }
			'z_web':   runtime_plan.ListenerPlan{ id: 'z_web', protocol: 'http' }
			'y_other': runtime_plan.ListenerPlan{ id: 'y_other', protocol: 'http' }
		}
		relays:    {
			'edge_a': runtime_plan.RelayPlan{ id: 'edge_a', mode: 'hub', carrier: 'websocket', ingress: runtime_plan.ResourceRef{ domain: .listener, id: 'a_relay' } }
			'edge_b': runtime_plan.RelayPlan{ id: 'edge_b', mode: 'hub', carrier: 'websocket', ingress: runtime_plan.ResourceRef{ domain: .listener, id: 'b_relay' } }
		}
		adapters:  {
			'delivery_a': runtime_plan.AdapterPlan{
				id:      'delivery_a'
				kind:    'relay-delivery'
				options: runtime_plan.PlanOptions{
					strings: {
						'target': 'relay:edge_a'
					}
				}
			}
			'delivery_b': runtime_plan.AdapterPlan{
				id:      'delivery_b'
				kind:    'relay-delivery'
				options: runtime_plan.PlanOptions{
					strings: {
						'target': 'relay:edge_b'
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{ id: 'deliver_a', ingress: runtime_plan.ResourceRef{ domain: .listener, id: 'z_web' }, egress: runtime_plan.ResourceRef{ domain: .adapter, id: 'delivery_a' } },
			runtime_plan.PipelinePlan{ id: 'deliver_b', ingress: runtime_plan.ResourceRef{ domain: .listener, id: 'z_web' }, egress: runtime_plan.ResourceRef{ domain: .adapter, id: 'delivery_b' } },
		]
	}
}

fn multi_app_root() string {
	return '/tmp/vhttpd-multi-owner-${os.getpid()}-${time.now().unix_micro()}'
}

fn multi_app_configs(plan runtime_plan.RuntimePlan, ids []string, root string) server_lifecycle.MultiServerRuntimeConfig {
	mut listeners := []server_lifecycle.ListenerRuntimeBinding{}
	for id in ids {
		build := server_lifecycle.AppRuntimeBuildConfig{ plan_listener_id: id, event_log: root + '/events', internal_admin_socket: root + '/${id}.sock' }
		listeners << server_lifecycle.ListenerRuntimeBinding{
			id:          id
			site_cfg:    config.default_vhttpd_config()
			runtime_cfg: server_lifecycle.ServerRuntimeConfig{
				plan:                  plan
				plan_listener_id:      id
				site_id:               id
				host:                  '127.0.0.1'
				port:                  18080
				ssl_enabled:           id == 'a_relay'
				internal_admin_socket: build.internal_admin_socket
				app_build_cfg:         build
				executor_plan:         executor.LogicExecutorRuntimePlan{ executor: executor.DisabledLogicExecutor{}, lifecycle: executor.disabled_executor_lifecycle() }
			}
		}
	}
	return server_lifecycle.MultiServerRuntimeConfig{ listeners: listeners }
}

fn multi_probe_factory(mut probe MultiAppProbe) AppRuntimeFactory {
	return fn [mut probe] (_ provider.ProviderRuntimeSettings, _ executor.LogicExecutorRuntimePlan, _ config.VhttpdConfig, _ runtime_plan.RuntimePlan, build server_lifecycle.AppRuntimeBuildConfig) &App {
		probe.record('build:${build.plan_listener_id}')
		return &App{ app_build_cfg: build, control_plane: ControlPlaneRuntime{ event_log: build.event_log }, engines: EngineRuntime{ primary: &worker.WorkerState{ logic_executor: MultiAppExecutor{ id: build.plan_listener_id, probe: probe } } } }
	}
}

fn test_multi_app_aliases_are_not_constructed_and_binding_order_is_preserved() {
	root := multi_app_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut probe := &MultiAppProbe{}
	cfg := multi_app_configs(multi_app_plan(), ['a_relay', 'c_solo', 'z_web', 'y_other', 'b_relay'], root)
	mut bindings := build_multi_server_apps_with_factory(cfg, multi_probe_factory(mut probe))
	assert probe.rows == ['build:c_solo', 'build:z_web', 'build:y_other']
	assert bindings.map(it.listener.id) == ['a_relay', 'c_solo', 'z_web', 'y_other', 'b_relay']
	assert bindings[0].app == bindings[2].app
	assert bindings[4].app == bindings[2].app
	assert bindings[1].app != bindings[2].app
	shutdown_multi_server_apps(mut bindings)
	assert probe.rows.filter(it.starts_with('close:')).sorted() == ['close:c_solo', 'close:y_other',
		'close:z_web']
}

fn test_multi_app_starts_once_with_owner_configuration_when_alias_is_first() {
	root := multi_app_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut probe := &MultiAppProbe{}
	cfg := multi_app_configs(multi_app_plan(), ['a_relay', 'b_relay', 'z_web'], root)
	mut bindings := build_multi_server_apps_with_factory(cfg, multi_probe_factory(mut probe))
	defer { shutdown_multi_server_apps(mut bindings) }
	start_multi_server_apps(mut bindings)
	assert probe.rows == ['build:z_web', 'warmup:z_web']
	assert bindings[0].app.lifecycle.data_plane_scheme == 'http'
	rows := os.read_lines(root + '/events') or { panic(err) }
	assert rows.filter(it.contains('"type":"server.started"')).len == 1
	assert os.exists(root + '/z_web.sock')
	assert !os.exists(root + '/a_relay.sock')
}

fn test_shared_app_plugin_lane_workers_have_one_constructor_and_a_cleanup_owner() {
	root := multi_app_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := root + '/plugin.mts'
	os.write_file(entry, 'export function plugin() { return {ok: true}; }') or { panic(err) }
	base := multi_app_plan()
	plan := runtime_plan.RuntimePlan{
		...base
		engines:    {
			'plugin': runtime_plan.EnginePlan{
				id:      'plugin'
				kind:    'vjsx'
				options: runtime_plan.PlanOptions{
					strings: {
						'entry':           entry
						'runtime_profile': 'node'
					}
					ints:    {
						'thread_count': 1
					}
				}
			}
		}
		transforms: {
			'global/plugin/test': runtime_plan.TransformPlan{ id: 'global/plugin/test', kind: 'vjsx', engine: runtime_plan.ResourceRef{ domain: .engine, id: 'plugin' } }
		}
	}
	mut probe := &MultiAppProbe{}
	defer {
		for mut app in probe.apps { app.close_all_plugins() }
	}
	factory := fn [mut probe] (settings provider.ProviderRuntimeSettings, exec_plan executor.LogicExecutorRuntimePlan, legacy config.VhttpdConfig, resolved runtime_plan.RuntimePlan, build server_lifecycle.AppRuntimeBuildConfig) &App {
		app := build_app_runtime(settings, exec_plan, legacy, resolved, build)
		probe.apps << app
		return app
	}
	mut bindings := build_multi_server_apps_with_factory(multi_app_configs(plan, [
		'a_relay',
		'b_relay',
		'z_web',
	], root), factory)
	assert probe.apps.len == 1
	plugin := bindings[0].app.protocols.plugins.vjsx['test'] or { panic('plugin not constructed') }
	assert bindings[0].app == bindings[2].app
	shutdown_multi_server_apps(mut bindings)
	mut closed := false
	plugin.bootstrap_placeholder() or {
		assert err.msg() == 'inproc_vjsx_executor_closed'
		closed = true
	}
	assert closed
}

fn test_failed_preflight_releases_resolved_executor_before_app_handoff() {
	root := multi_app_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut probe := &MultiAppProbe{}
	cfg := server_lifecycle.ServerRuntimeConfig{ serve_data_plane: true, port: 0, executor_plan: executor.LogicExecutorRuntimePlan{ executor: MultiAppExecutor{ id: 'preflight', probe: probe }, lifecycle: executor.disabled_executor_lifecycle() } }
	mut failed := false
	run_single_server_with_config(config.default_vhttpd_config(), cfg) or { failed = true }
	assert failed
	assert probe.rows == ['close:preflight']
}

fn test_untransferred_multi_configs_close_shared_executor_only_once() {
	root := multi_app_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut probe := &MultiAppProbe{}
	base := multi_app_configs(multi_app_plan(), ['a_relay', 'b_relay', 'z_web'], root)
	shared := executor.LogicExecutorRuntimePlan{ executor: MultiAppExecutor{ id: 'shared', probe: probe }, lifecycle: executor.disabled_executor_lifecycle() }
	mut listeners := []server_lifecycle.ListenerRuntimeBinding{}
	for listener in base.listeners {
		listeners << server_lifecycle.ListenerRuntimeBinding{ ...listener, runtime_cfg: server_lifecycle.ServerRuntimeConfig{ ...listener.runtime_cfg, executor_plan: shared } }
	}
	server_lifecycle.MultiServerRuntimeConfig{ listeners: listeners }.close_untransferred_executors()
	assert probe.rows == ['close:shared']
}

fn test_multi_config_alias_borrows_owner_executor_but_keeps_its_listener_metadata() {
	root := multi_app_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := root + '/app.mts'
	os.write_file(entry, 'export default { handle() { return {status:200,body:"ok"}; } };') or { panic(err) }
	file := root + '/config.toml'
	os.write_file(file, 'version = 2
[server]
pid_file = "${root}/server.pid"
[observability]
event_log = "${root}/events"
[listeners.a_relay]
protocol = "websocket"
transport = "tcp"
port = 18701
[listeners.z_web]
protocol = "http"
transport = "tcp"
port = 18702
[relays.edge]
mode = "hub"
carrier = "websocket"
listener = "listener:a_relay"
[engines.app]
kind = "vjsx"
entry = "${entry}"
[adapters.app]
kind = "http-handler"
engine = "engine:app"
[adapters.delivery]
kind = "relay-delivery"
options.target = "relay:edge"
[[pipelines]]
id = "deliver"
ingress = "listener:z_web"
match.paths = ["/relay"]
egress = "adapter:delivery"
[[pipelines]]
id = "app"
ingress = "listener:z_web"
match.paths = ["*"]
egress = "adapter:app"
') or { panic(err) }
	args := ['--config', file, '--admin-port', '19992']
	legacy := config.load_vhttpd_config(args) or { panic(err) }
	resolved := server_lifecycle.resolve_multi_server_runtime_config(args, legacy) or { panic(err) }
	defer { resolved.close_untransferred_executors() }
	assert resolved.listeners.map(it.id) == ['a_relay', 'z_web']
	alias := resolved.listeners[0].runtime_cfg
	owner := resolved.listeners[1].runtime_cfg
	assert alias.port == 18701 && owner.port == 18702
	assert alias.plan_listener_id == 'a_relay' && owner.plan_listener_id == 'z_web'
	assert !alias.admin_enabled
	assert owner.admin_enabled
	assert owner.app_build_cfg.admin_enabled
	a := alias.executor_plan.executor
	b := owner.executor_plan.executor
	assert a is executor.InProcVjsxExecutor
	assert b is executor.InProcVjsxExecutor
	if a is executor.InProcVjsxExecutor {
		if b is executor.InProcVjsxExecutor {
			assert voidptr(a.state) == voidptr(b.state)
		}
	}
}
