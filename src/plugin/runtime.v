module plugin

import config
import executor
import log

pub fn plugin_config_app_entry(cfg config.PluginConfig) string {
	if cfg.app_entry.trim_space() != '' {
		return cfg.app_entry.trim_space()
	}
	return cfg.entry.trim_space()
}

pub fn vjsx_plugin_runtime_config(name string, cfg config.PluginConfig) !executor.VjsxRuntimeFacadeConfig {
	app_entry := plugin_config_app_entry(cfg)
	embedded_cfg := config.EmbeddedHostRuntimeConfig.resolve([]string{}, config.EmbeddedHostRuntimeConfig{
		app_entry:         app_entry
		module_root:       cfg.module_root
		build_root:        cfg.build_root
		signature_root:    cfg.signature_root
		signature_include: cfg.signature_include.clone()
		signature_exclude: cfg.signature_exclude.clone()
		runtime_profile:   cfg.runtime_profile
		lane_count:        cfg.thread_count
		max_requests:      cfg.max_requests
		enable_fs:         cfg.enable_fs
		enable_process:    cfg.enable_process
		enable_network:    cfg.enable_network
	}, config.EmbeddedHostCliOverrides{}) or {
		return error('plugin_runtime_config_failed:${name}:${err.msg()}')
	}
	return executor.VjsxRuntimeFacadeConfig{
		app_entry:         embedded_cfg.app_entry
		module_root:       embedded_cfg.module_root
		build_root:        embedded_cfg.build_root
		signature_root:    embedded_cfg.signature_root
		signature_include: embedded_cfg.signature_include.clone()
		signature_exclude: embedded_cfg.signature_exclude.clone()
		runtime_profile:   embedded_cfg.runtime_profile
		thread_count:      embedded_cfg.lane_count
		max_requests:      embedded_cfg.max_requests
		enable_fs:         embedded_cfg.enable_fs
		enable_process:    embedded_cfg.enable_process
		enable_network:    embedded_cfg.enable_network
	}
}

pub fn build_vjsx_plugin_runtimes(configs map[string]config.PluginConfig) map[string]executor.InProcVjsxExecutor {
	mut runtimes := map[string]executor.InProcVjsxExecutor{}
	for name, cfg in configs {
		if cfg.kind.trim_space().to_lower() !in ['', 'vjsx'] {
			continue
		}
		runtime_cfg := vjsx_plugin_runtime_config(name, cfg) or {
			log.warn('[vhttpd] plugin runtime unavailable name=${name} kind=${cfg.kind} entry=${plugin_config_app_entry(cfg)} error=${err.msg()}')
			continue
		}
		runtimes[name] = executor.new_inproc_vjsx_executor(runtime_cfg)
	}
	return runtimes
}
