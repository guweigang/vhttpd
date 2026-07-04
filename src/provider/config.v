module provider

import config
import feishu

// Provider runtime settings are resolved here so server.v can stay focused on
// transport/process orchestration instead of provider-specific defaults.

pub struct FeishuRuntimeSettings {
pub:
	enabled                    bool
	runtime_driver             string
	runtime_plugin             string
	open_base_url              string
	reconnect_delay_ms         int
	token_refresh_skew_seconds int
	recent_event_limit         int
	apps                       map[string]config.FeishuAppConfig
}

pub struct CodexRuntimeSettings {
pub:
	enabled            bool
	url                string
	model              string
	effort             string
	cwd                string
	approval_policy    string
	sandbox            string
	reconnect_delay_ms int
	flush_interval_ms  int
}

pub struct DbRuntimeSettings {
pub:
	enabled      bool
	socket       string
	driver       string
	pool_name    string
	host         string
	port         int
	username     string
	password     string
	database     string
	pool_size    int
	idle_ping_ms int
	init_sql     []string
}

pub struct BridgeRuntimeSettings {
pub:
	enabled   bool
	ws_url    string
	client_id string
	token     string
	target_id string
}

pub struct ProviderRuntimeSettings {
pub:
	runtime_drivers      map[string]string
	runtime_plugins      map[string]string
	runtime_capabilities map[string]map[string]string
	runtime_options      map[string]map[string]string
	feishu               FeishuRuntimeSettings
	codex                CodexRuntimeSettings
	bridge               BridgeRuntimeSettings
	db                   DbRuntimeSettings
	ollama_enabled       bool
}

pub fn ProviderRuntimeSettings.resolve(args []string, cfg config.VhttpdConfig) ProviderRuntimeSettings {
	db_driver := normalize_db_driver(cfg.db.driver)
	db_host := if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
		if cfg.db.pgsql.host.trim_space() != '' { cfg.db.pgsql.host } else { '127.0.0.1' }
	} else {
		if cfg.db.mysql.host.trim_space() != '' { cfg.db.mysql.host } else { '127.0.0.1' }
	}
	db_port := if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
		if cfg.db.pgsql.port > 0 { cfg.db.pgsql.port } else { 5432 }
	} else {
		if cfg.db.mysql.port > 0 { cfg.db.mysql.port } else { 3306 }
	}
	db_username := if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
		cfg.db.pgsql.username
	} else {
		cfg.db.mysql.username
	}
	db_password := if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
		cfg.db.pgsql.password
	} else {
		cfg.db.mysql.password
	}
	db_database := if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
		if cfg.db.pgsql.database.trim_space() != '' { cfg.db.pgsql.database } else { 'postgres' }
	} else {
		if cfg.db.mysql.database.trim_space() != '' { cfg.db.mysql.database } else { 'mysql' }
	}
	db_pool_size := if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
		if cfg.db.pgsql.pool_size > 0 { cfg.db.pgsql.pool_size } else { 5 }
	} else {
		if cfg.db.mysql.pool_size > 0 { cfg.db.mysql.pool_size } else { 5 }
	}
	feishu_enabled := config.CliArgs.bool_or(args, '--feishu-enabled', cfg.feishu.enabled)
	feishu_app_id := config.CliArgs.string_or(args, '--feishu-app-id', '')
	feishu_app_secret := config.CliArgs.string_or(args, '--feishu-app-secret', '')
	feishu_open_base_url := feishu.RuntimeWsEndpointData.normalize_open_base(config.CliArgs.string_or(args,
		'--feishu-open-base-url', cfg.feishu.open_base_url))
	mut feishu_apps := cfg.feishu.apps.clone()
	if feishu_app_id.trim_space() != '' || feishu_app_secret.trim_space() != '' {
		feishu_apps['main'] = config.FeishuAppConfig{
			app_id:     feishu_app_id
			app_secret: feishu_app_secret
		}
	}
	runtime_drivers, runtime_plugins := provider_runtime_maps_from_config(cfg)
	runtime_capabilities := provider_runtime_capability_maps_from_config(cfg)
	runtime_options := provider_runtime_option_maps_from_config(cfg)

	return ProviderRuntimeSettings{
		runtime_drivers:      runtime_drivers
		runtime_plugins:      runtime_plugins
		runtime_capabilities: runtime_capabilities
		runtime_options:      runtime_options
		feishu:               FeishuRuntimeSettings{
			enabled:                    feishu_enabled
			runtime_driver:             runtime_drivers['feishu'] or { 'native' }
			runtime_plugin:             runtime_plugins['feishu'] or { '' }
			open_base_url:              feishu_open_base_url
			reconnect_delay_ms:         if cfg.feishu.reconnect_delay_ms > 0 {
				cfg.feishu.reconnect_delay_ms
			} else {
				3000
			}
			token_refresh_skew_seconds: if cfg.feishu.token_refresh_skew_seconds > 0 {
				cfg.feishu.token_refresh_skew_seconds
			} else {
				60
			}
			recent_event_limit:         if cfg.feishu.recent_event_limit > 0 {
				cfg.feishu.recent_event_limit
			} else {
				20
			}
			apps:                       feishu_apps.clone()
		}
		codex:                CodexRuntimeSettings{
			enabled:            cfg.codex.enabled
			url:                if cfg.codex.url.trim_space() != '' {
				cfg.codex.url
			} else {
				'ws://127.0.0.1:4500'
			}
			model:              if cfg.codex.model.trim_space() != '' {
				cfg.codex.model
			} else {
				'o4-mini'
			}
			effort:             if cfg.codex.effort.trim_space() != '' {
				cfg.codex.effort
			} else {
				'medium'
			}
			cwd:                cfg.codex.cwd
			approval_policy:    if cfg.codex.approval_policy.trim_space() != '' {
				cfg.codex.approval_policy
			} else {
				'never'
			}
			sandbox:            if cfg.codex.sandbox.trim_space() != '' {
				cfg.codex.sandbox
			} else {
				'workspaceWrite'
			}
			reconnect_delay_ms: if cfg.codex.reconnect_delay_ms > 0 {
				cfg.codex.reconnect_delay_ms
			} else {
				3000
			}
			flush_interval_ms:  if cfg.codex.flush_interval_ms > 0 {
				cfg.codex.flush_interval_ms
			} else {
				400
			}
		}
		bridge:               BridgeRuntimeSettings{
			enabled:   cfg.feishu.bridge.enabled
			ws_url:    cfg.feishu.bridge.ws_url
			client_id: cfg.feishu.bridge.client_id
			token:     cfg.feishu.bridge.token
			target_id: cfg.feishu.bridge.target_id
		}
		db:                   DbRuntimeSettings{
			enabled:      cfg.db.enabled
			socket:       if cfg.db.socket.trim_space() != '' {
				cfg.db.socket
			} else {
				'tmp/vhttpd-db.sock'
			}
			driver:       db_driver
			pool_name:    if cfg.db.pool_name.trim_space() != '' {
				cfg.db.pool_name
			} else {
				'default'
			}
			host:         db_host
			port:         db_port
			username:     db_username
			password:     db_password
			database:     db_database
			pool_size:    db_pool_size
			idle_ping_ms: if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
				0
			} else {
				cfg.db.mysql.idle_ping_ms
			}
			init_sql:     if db_driver in ['pgsql', 'pg', 'postgres', 'postgresql'] {
				[]string{}
			} else {
				cfg.db.mysql.init_sql.clone()
			}
		}
		ollama_enabled:       config.CliArgs.bool_or(args, '--ollama-enabled', false)
	}
}

fn provider_runtime_capability_maps_from_config(cfg config.VhttpdConfig) map[string]map[string]string {
	mut capability_routes := map[string]map[string]string{}
	for name, provider_cfg in cfg.providers {
		if provider_cfg.capabilities.len > 0 {
			capability_routes[name] = provider_cfg.capabilities.clone()
		}
	}
	return capability_routes
}

fn provider_runtime_option_maps_from_config(cfg config.VhttpdConfig) map[string]map[string]string {
	_ = cfg
	return map[string]map[string]string{}
}

fn provider_runtime_maps_from_config(cfg config.VhttpdConfig) (map[string]string, map[string]string) {
	mut drivers := map[string]string{}
	mut plugins := map[string]string{}
	drivers['feishu'] = normalize_runtime_driver(cfg.feishu.runtime_driver)
	if cfg.feishu.runtime_plugin.trim_space() != '' {
		plugins['feishu'] = cfg.feishu.runtime_plugin
	}
	for name, provider_cfg in cfg.providers {
		runtime_driver := if provider_cfg.runtime.driver.trim_space() != '' {
			provider_cfg.runtime.driver
		} else {
			provider_cfg.runtime_driver
		}
		runtime_plugin := if provider_cfg.runtime.plugin.trim_space() != '' {
			provider_cfg.runtime.plugin
		} else {
			provider_cfg.runtime_plugin
		}
		drivers[name] = normalize_runtime_driver(runtime_driver)
		if runtime_plugin.trim_space() != '' {
			plugins[name] = runtime_plugin
		} else {
			plugins.delete(name)
		}
	}
	for name in ['codex', 'db', 'cache'] {
		if name !in drivers {
			drivers[name] = 'native'
		}
	}
	return drivers, plugins
}

pub fn normalize_db_driver(name string) string {
	driver := name.trim_space().to_lower()
	return match driver {
		'pg', 'postgres', 'postgresql' {
			'pgsql'
		}
		'mysql' {
			'mysql'
		}
		else {
			if driver != '' {
				driver
			} else {
				'mysql'
			}
		}
	}
}

pub fn normalize_runtime_driver(name string) string {
	driver := name.trim_space().to_lower()
	if driver == '' {
		return 'native'
	}
	return match driver {
		'native', 'v', 'builtin' {
			'native'
		}
		'vjsx', 'js', 'javascript', 'typescript', 'ts' {
			'vjsx'
		}
		else {
			driver
		}
	}
}
