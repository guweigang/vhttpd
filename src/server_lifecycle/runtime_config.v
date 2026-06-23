module server_lifecycle

import config
import os
import admin
import executor
import provider
import runtime_plan

pub struct AppRuntimeBuildConfig {
pub:
	plan_listener_id              string
	event_log                     string
	internal_admin_socket         string
	admin_enabled                 bool
	admin_token                   string
	assets_enabled                bool
	assets_prefix                 string
	assets_root                   string
	assets_root_real              string
	assets_cache_control          string
	worker_read_timeout_ms        int
	worker_restart_backoff_ms     int
	worker_restart_backoff_max_ms int
	worker_max_requests           int
	worker_queue_capacity         int
	worker_queue_timeout_ms       int
	workdir                       string
}

pub struct ServerRuntimeConfig {
pub:
	plan                  runtime_plan.RuntimePlan
	plan_listener_id      string
	listener_id           string
	site_id               string
	host                  string
	port                  int
	ssl_enabled           bool
	ssl_cert              string
	ssl_cert_key          string
	pid_file              string
	admin_enabled         bool
	admin_host            string
	admin_port            int
	admin_token           string
	internal_admin_socket string
	provider_settings     provider.ProviderRuntimeSettings
	executor_plan         executor.LogicExecutorRuntimePlan
	app_build_cfg         AppRuntimeBuildConfig
}

pub fn ServerRuntimeConfig.resolve(args []string, cfg config.VhttpdConfig) !ServerRuntimeConfig {
	host := config.CliArgs.string_or(args, '--host', cfg.server.host)
	port := config.CliArgs.int_or(args, '--port', cfg.server.port)
	plan := config.compile_v1_runtime_plan(cfg)!
	return ServerRuntimeConfig.resolve_for_target_with_plan(args, cfg, '', '', host, port,
		cfg.server.ssl, true, plan, 'default')
}

pub fn ServerRuntimeConfig.resolve_for_target(args []string, cfg config.VhttpdConfig, listener_id string, site_id string, host string, port int, ssl config.ServerSslConfig, admin_enabled_override bool) !ServerRuntimeConfig {
	plan := config.compile_v1_runtime_plan(cfg)!
	return ServerRuntimeConfig.resolve_for_target_with_plan(args, cfg, listener_id, site_id, host,
		port, ssl, admin_enabled_override, plan, 'default')
}

pub fn ServerRuntimeConfig.resolve_for_target_with_plan(args []string, cfg config.VhttpdConfig, listener_id string, site_id string, host string, port int, ssl config.ServerSslConfig, admin_enabled_override bool, plan runtime_plan.RuntimePlan, plan_listener_id string) !ServerRuntimeConfig {
	resolved_plan := config.runtime_plan_apply_cli_overrides(args, cfg, plan, plan_listener_id)
	event_log := config.CliArgs.string_or(args, '--event-log', plan_event_log(resolved_plan,
		cfg.files.event_log))
	pid_file := config.CliArgs.string_or(args, '--pid-file', plan_pid_file(resolved_plan,
		cfg.files.pid_file))
	worker_read_timeout_ms := config.CliArgs.int_or(args, '--worker-read-timeout-ms',
		cfg.worker.read_timeout_ms)
	worker_restart_backoff_ms := config.CliArgs.int_or(args, '--worker-restart-backoff-ms',
		cfg.worker.restart_backoff_ms)
	worker_restart_backoff_max_ms := config.CliArgs.int_or(args, '--worker-restart-backoff-max-ms',
		cfg.worker.restart_backoff_max_ms)
	worker_max_requests := config.CliArgs.int_or(args, '--worker-max-requests',
		cfg.worker.max_requests)
	worker_queue_capacity := config.CliArgs.int_or(args, '--worker-queue-capacity',
		cfg.worker.queue_capacity)
	worker_queue_timeout_ms := config.CliArgs.int_or(args, '--worker-queue-timeout-ms',
		cfg.worker.queue_timeout_ms)
	assets_cfg := assets_runtime_from_plan(resolved_plan, plan_listener_id, cfg.assets)
	assets_enabled := assets_cfg.enabled
	assets_prefix := assets_cfg.prefix
	assets_root := assets_cfg.root
	assets_root_real := if assets_root.trim_space() == '' { '' } else { os.real_path(assets_root) }
	assets_cache_control := assets_cfg.cache_control
	admin_host_arg := config.CliArgs.string_or(args, '--admin-host', cfg.admin.host).trim_space()
	admin_port := config.CliArgs.int_or(args, '--admin-port', cfg.admin.port)
	admin_token := config.CliArgs.string_or(args, '--admin-token', plan_admin_token(resolved_plan,
		cfg.admin.token))
	admin_enabled := admin_enabled_override && admin_port > 0
	admin_host := if admin_host_arg == '' { '127.0.0.1' } else { admin_host_arg }
	ssl_cert := config.CliArgs.string_or(args, '--ssl-cert', ssl.cert)
	ssl_cert_key := config.CliArgs.string_or(args, '--ssl-key', ssl.cert_key)
	ssl_enabled := ssl.enabled || (ssl_cert.trim_space() != '' && ssl_cert_key.trim_space() != '')
	provider_settings := provider.ProviderRuntimeSettings.resolve(args, cfg)
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan(args, cfg, resolved_plan,
		plan_listener_id)!
	workdir := os.getwd()
	socket_label := if listener_id != '' {
		listener_id
	} else if site_id != '' {
		site_id
	} else {
		''
	}
	internal_admin_socket := prepare_server_runtime_files_for_label(event_log, pid_file,
		socket_label)!
	return ServerRuntimeConfig{
		plan:                  resolved_plan
		plan_listener_id:      plan_listener_id
		listener_id:           listener_id
		site_id:               site_id
		host:                  host
		port:                  port
		ssl_enabled:           ssl_enabled
		ssl_cert:              ssl_cert
		ssl_cert_key:          ssl_cert_key
		pid_file:              pid_file
		admin_enabled:         admin_enabled
		admin_host:            admin_host
		admin_port:            admin_port
		admin_token:           admin_token
		internal_admin_socket: internal_admin_socket
		provider_settings:     provider_settings
		executor_plan:         executor_plan
		app_build_cfg:         AppRuntimeBuildConfig{
			plan_listener_id:              plan_listener_id
			event_log:                     event_log
			internal_admin_socket:         internal_admin_socket
			admin_enabled:                 admin_enabled
			admin_token:                   admin_token
			assets_enabled:                assets_enabled
			assets_prefix:                 assets_prefix
			assets_root:                   assets_root
			assets_root_real:              assets_root_real
			assets_cache_control:          assets_cache_control
			worker_read_timeout_ms:        worker_read_timeout_ms
			worker_restart_backoff_ms:     worker_restart_backoff_ms
			worker_restart_backoff_max_ms: worker_restart_backoff_max_ms
			worker_max_requests:           worker_max_requests
			worker_queue_capacity:         worker_queue_capacity
			worker_queue_timeout_ms:       worker_queue_timeout_ms
			workdir:                       workdir
		}
	}
}

pub fn normalize_assets_prefix(raw string) string {
	mut prefix := raw.trim_space()
	if prefix == '' {
		return '/assets'
	}
	if !prefix.starts_with('/') {
		prefix = '/${prefix}'
	}
	for prefix.len > 1 && prefix.ends_with('/') {
		prefix = prefix[..prefix.len - 1]
	}
	return prefix
}

fn plan_event_log(plan runtime_plan.RuntimePlan, fallback string) string {
	return if plan.observability.event_log.trim_space() != '' {
		plan.observability.event_log
	} else {
		fallback
	}
}

fn plan_pid_file(plan runtime_plan.RuntimePlan, fallback string) string {
	return if plan.server.pid_file.trim_space() != '' { plan.server.pid_file } else { fallback }
}

fn plan_admin_token(plan runtime_plan.RuntimePlan, fallback string) string {
	return if plan.control.token.trim_space() != '' { plan.control.token } else { fallback }
}

fn assets_runtime_from_plan(plan runtime_plan.RuntimePlan, listener_id string, fallback config.AssetsConfig) config.AssetsRuntime {
	adapter, prefix := assets_adapter_from_plan(plan, listener_id) or {
		return config.AssetsRuntime{
			enabled:       fallback.enabled
			prefix:        normalize_assets_prefix(fallback.prefix)
			root:          fallback.root
			cache_control: fallback.cache_control
		}
	}
	return config.AssetsRuntime{
		enabled:       true
		prefix:        normalize_assets_prefix(prefix)
		root:          adapter.options.strings['root']
		cache_control: assets_cache_control_from_plan(plan, listener_id, fallback.cache_control)
	}
}

fn assets_adapter_from_plan(plan runtime_plan.RuntimePlan, listener_id string) ?(runtime_plan.AdapterPlan, string) {
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind != 'static' || (!pipeline.id.ends_with('_assets') && !adapter.id.ends_with('/assets')) {
			continue
		}
		prefix := if pipeline.match.paths.len > 0 { pipeline.match.paths[0] } else { '/assets' }
		return adapter, prefix
	}
	return none
}

fn assets_cache_control_from_plan(plan runtime_plan.RuntimePlan, listener_id string, fallback string) string {
	for pipeline in plan.listener_pipelines(listener_id) {
		if !pipeline.id.ends_with('_assets') {
			continue
		}
		for policy_ref in pipeline.policies {
			policy := plan.policies[policy_ref.id] or { continue }
			if policy.category == 'cache' && policy.options.strings['cache_control'] != '' {
				return policy.options.strings['cache_control']
			}
		}
	}
	return fallback
}

pub fn prepare_server_runtime_files_for_label(event_log string, pid_file string, socket_label string) !string {
	os.mkdir_all(os.dir(event_log))!
	os.mkdir_all(os.dir(pid_file))!
	os.write_file(pid_file, '${os.getpid()}')!
	return admin.AdminState.default_socket_for(socket_label)
}
