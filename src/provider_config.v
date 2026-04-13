module main

// Provider runtime settings are resolved here so server.v can stay focused on
// transport/process orchestration instead of provider-specific defaults.

struct FeishuRuntimeSettings {
	enabled                    bool
	open_base_url              string
	reconnect_delay_ms         int
	token_refresh_skew_seconds int
	recent_event_limit         int
	apps                       map[string]FeishuAppConfig
}

struct CodexRuntimeSettings {
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

struct DbRuntimeSettings {
	enabled   bool
	socket    string
	driver    string
	host      string
	port      int
	username  string
	password  string
	database  string
	pool_size int
}

struct BridgeRuntimeSettings {
	enabled   bool
	ws_url    string
	client_id string
	token     string
	target_id string
}

struct ProviderRuntimeSettings {
	feishu         FeishuRuntimeSettings
	codex          CodexRuntimeSettings
	bridge         BridgeRuntimeSettings
	db             DbRuntimeSettings
	ollama_enabled bool
}

fn resolve_provider_runtime_settings(args []string, cfg VhttpdConfig) ProviderRuntimeSettings {
	db_driver := normalize_db_driver_name(cfg.db.driver)
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
	feishu_enabled := arg_bool_or(args, '--feishu-enabled', cfg.feishu.enabled)
	feishu_app_id := arg_string_or(args, '--feishu-app-id', '')
	feishu_app_secret := arg_string_or(args, '--feishu-app-secret', '')
	feishu_open_base_url := normalize_feishu_open_base(arg_string_or(args, '--feishu-open-base-url',
		cfg.feishu.open_base_url))
	mut feishu_apps := cfg.feishu.apps.clone()
	if feishu_app_id.trim_space() != '' || feishu_app_secret.trim_space() != '' {
		feishu_apps['main'] = FeishuAppConfig{
			app_id:     feishu_app_id
			app_secret: feishu_app_secret
		}
	}

	return ProviderRuntimeSettings{
		feishu:         FeishuRuntimeSettings{
			enabled:                    feishu_enabled
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
		codex:          CodexRuntimeSettings{
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
		bridge:         BridgeRuntimeSettings{
			enabled:   cfg.feishu.bridge.enabled
			ws_url:    cfg.feishu.bridge.ws_url
			client_id: cfg.feishu.bridge.client_id
			token:     cfg.feishu.bridge.token
			target_id: cfg.feishu.bridge.target_id
		}
		db:             DbRuntimeSettings{
			enabled:   cfg.db.enabled
			socket:    if cfg.db.socket.trim_space() != '' {
				cfg.db.socket
			} else {
				'tmp/vhttpd-db.sock'
			}
			driver:    db_driver
			host:      db_host
			port:      db_port
			username:  db_username
			password:  db_password
			database:  db_database
			pool_size: db_pool_size
		}
		ollama_enabled: arg_bool_or(args, '--ollama-enabled', false)
	}
}
