module main

import os
import toml

struct ServerConfig {
mut:
	host string = '127.0.0.1'
	port int    = 18081
}

struct FilesConfig {
mut:
	event_log string = '/tmp/vhttpd.events.ndjson'
	pid_file  string = '/tmp/vhttpd.pid'
}

struct WorkerConfig {
mut:
	read_timeout_ms        int = 3000 @[toml: 'read_timeout_ms']
	autostart              bool
	cmd                    string
	stream_dispatch        bool @[toml: 'stream_dispatch']
	queue_capacity         int @[toml: 'queue_capacity']
	queue_timeout_ms       int @[toml: 'queue_timeout_ms']
	restart_backoff_ms     int = 500  @[toml: 'restart_backoff_ms']
	restart_backoff_max_ms int = 8000  @[toml: 'restart_backoff_max_ms']
	max_requests           int  @[toml: 'max_requests']
	socket                 string
	pool_size              int = 1    @[toml: 'pool_size']
	websocket_dispatch     bool   @[toml: 'websocket_dispatch']
	socket_prefix          string @[toml: 'socket_prefix']
	sockets                []string
	env                    map[string]string
}

struct AdminConfig {
mut:
	host  string = '127.0.0.1'
	port  int
	token string
}

struct AssetsConfig {
mut:
	enabled       bool
	prefix        string = '/assets'
	root          string
	cache_control string = 'public, max-age=3600' @[toml: 'cache_control']
}

struct RuntimeConfig {
mut:
	timezone string = 'Asia/Shanghai'
}

struct McpConfig {
mut:
	max_sessions               int = 1000      @[toml: 'max_sessions']
	max_pending_messages       int = 128      @[toml: 'max_pending_messages']
	session_ttl_seconds        int = 900      @[toml: 'session_ttl_seconds']
	allowed_origins            []string @[toml: 'allowed_origins']
	sampling_capability_policy string = 'warn'   @[toml: 'sampling_capability_policy']
}

struct FeishuConfig {
mut:
	enabled                    bool
	open_base_url              string = 'https://open.feishu.cn/open-apis' @[toml: 'open_base_url']
	reconnect_delay_ms         int    = 3000    @[toml: 'reconnect_delay_ms']
	token_refresh_skew_seconds int    = 60    @[toml: 'token_refresh_skew_seconds']
	recent_event_limit         int    = 20    @[toml: 'recent_event_limit']
	apps                       map[string]FeishuAppConfig
}

struct FeishuAppConfig {
mut:
	app_id             string @[toml: 'app_id']
	app_secret         string @[toml: 'app_secret']
	verification_token string @[toml: 'verification_token']
	encrypt_key        string @[toml: 'encrypt_key']
}

struct CodexConfig {
mut:
	enabled            bool
	url                string = 'ws://127.0.0.1:4500' @[toml: 'url']
	model              string = 'o4-mini'              @[toml: 'model']
	effort             string = 'medium'                @[toml: 'effort']
	cwd                string
	approval_policy    string = 'never'                 @[toml: 'approval_policy']
	sandbox            string = 'workspaceWrite'        @[toml: 'sandbox']
	reconnect_delay_ms int    = 3000                    @[toml: 'reconnect_delay_ms']
	flush_interval_ms  int    = 400                     @[toml: 'flush_interval_ms']
}

struct VhttpdConfig {
mut:
	server ServerConfig
	files  FilesConfig
	worker WorkerConfig
	admin  AdminConfig
	assets AssetsConfig
	runtime RuntimeConfig
	mcp    McpConfig
	feishu FeishuConfig
	codex  CodexConfig
}

fn default_vhttpd_config() VhttpdConfig {
	return VhttpdConfig{}
}

fn arg_has(args []string, key string) bool {
	for a in args {
		if a == key || a.starts_with('${key}=') {
			return true
		}
	}
	return false
}

fn arg_string_or(args []string, key string, default_val string) string {
	if !arg_has(args, key) {
		return default_val
	}
	return get_arg(args, key, default_val)
}

fn arg_int_or(args []string, key string, default_val int) int {
	if !arg_has(args, key) {
		return default_val
	}
	raw := get_arg(args, key, '${default_val}')
	return raw.int()
}

fn parse_boolish(raw string) bool {
	return raw.trim_space().to_lower() in ['1', 'true', 'yes', 'on']
}

fn arg_bool_or(args []string, key string, default_val bool) bool {
	for i, a in args {
		if a == key {
			if i + 1 < args.len && !args[i + 1].starts_with('--') {
				return parse_boolish(args[i + 1])
			}
			return true
		}
		prefix := '${key}='
		if a.starts_with(prefix) {
			return parse_boolish(a.all_after(prefix))
		}
	}
	return default_val
}

fn load_vhttpd_config(args []string) !VhttpdConfig {
	mut config_path := arg_string_or(args, '--config', '')
	if config_path == '' {
		config_path = os.getenv('VHTTPD_CONFIG')
	}
	if config_path == '' {
		for a in args {
			if a.starts_with('--') {
				continue
			}
			if a.to_lower().ends_with('.toml') {
				config_path = a
				break
			}
		}
	}
	if config_path == '' {
		return default_vhttpd_config()
	}
	text := os.read_file(config_path)!
	mut cfg := toml.decode[VhttpdConfig](text)!
	doc := toml.parse_text(text)!
	decode_feishu_config(doc, mut cfg)!
	resolve_config_variables(mut cfg)!
	return cfg
}

fn decode_feishu_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	mut apps := map[string]FeishuAppConfig{}
	if root_any := doc.value_opt('feishu') {
		root := root_any.as_map()
		root_app_id := (root['app_id'] or { toml.Any('') }).string()
		root_app_secret := (root['app_secret'] or { toml.Any('') }).string()
		root_verification_token := (root['verification_token'] or { toml.Any('') }).string()
		root_encrypt_key := (root['encrypt_key'] or { toml.Any('') }).string()
		if root_app_id != '' || root_app_secret != '' || root_verification_token != '' || root_encrypt_key != '' {
			apps['main'] = FeishuAppConfig{
				app_id:             root_app_id
				app_secret:         root_app_secret
				verification_token: root_verification_token
				encrypt_key:        root_encrypt_key
			}
		}
		for name, value in root {
			if name in ['enabled', 'open_base_url', 'reconnect_delay_ms',
				'token_refresh_skew_seconds', 'recent_event_limit', 'app_id', 'app_secret', 'verification_token', 'encrypt_key'] {
				continue
			}
			if value is map[string]toml.Any {
				entry := value as map[string]toml.Any
				app_id := (entry['app_id'] or { toml.Any('') }).string()
				app_secret := (entry['app_secret'] or { toml.Any('') }).string()
				verification_token := (entry['verification_token'] or { toml.Any('') }).string()
				encrypt_key := (entry['encrypt_key'] or { toml.Any('') }).string()
				if app_id == '' && app_secret == '' && verification_token == '' && encrypt_key == '' {
					continue
				}
				apps[name] = FeishuAppConfig{
					app_id:             app_id
					app_secret:         app_secret
					verification_token: verification_token
					encrypt_key:        encrypt_key
				}
			}
		}
	}
	cfg.feishu.apps = apps.clone()
}

fn resolve_config_variables(mut cfg VhttpdConfig) ! {
	env_map := os.environ()
	max_passes := 12
	for _ in 0 .. max_passes {
		mut changed := false
		vars := build_config_variable_map(cfg)
		cfg.server.host, changed = expand_config_string(cfg.server.host, vars, env_map,
			changed)!
		cfg.files.event_log, changed = expand_config_string(cfg.files.event_log, vars,
			env_map, changed)!
		cfg.files.pid_file, changed = expand_config_string(cfg.files.pid_file, vars, env_map,
			changed)!
		cfg.worker.cmd, changed = expand_config_string(cfg.worker.cmd, vars, env_map,
			changed)!
		cfg.worker.socket, changed = expand_config_string(cfg.worker.socket, vars, env_map,
			changed)!
		cfg.worker.socket_prefix, changed = expand_config_string(cfg.worker.socket_prefix,
			vars, env_map, changed)!
		for i, raw in cfg.worker.sockets {
			next, c := expand_config_string(raw, vars, env_map, false)!
			if c {
				cfg.worker.sockets[i] = next
				changed = true
			}
		}
		mut next_env := map[string]string{}
		for key, value in cfg.worker.env {
			next, c := expand_config_string(value, vars, env_map, false)!
			next_env[key] = next
			if c {
				changed = true
			}
		}
		cfg.worker.env = next_env.clone()
		cfg.admin.host, changed = expand_config_string(cfg.admin.host, vars, env_map,
			changed)!
		cfg.admin.token, changed = expand_config_string(cfg.admin.token, vars, env_map,
			changed)!
		cfg.assets.prefix, changed = expand_config_string(cfg.assets.prefix, vars, env_map,
			changed)!
		cfg.assets.root, changed = expand_config_string(cfg.assets.root, vars, env_map,
			changed)!
		cfg.assets.cache_control, changed = expand_config_string(cfg.assets.cache_control,
			vars, env_map, changed)!
		cfg.runtime.timezone, changed = expand_config_string(cfg.runtime.timezone, vars, env_map, changed)!
		cfg.feishu.open_base_url, changed = expand_config_string(cfg.feishu.open_base_url,
			vars, env_map, changed)!
		mut next_apps := map[string]FeishuAppConfig{}
		for name, app_cfg in cfg.feishu.apps {
			app_id, app_id_changed := expand_config_string(app_cfg.app_id, vars, env_map,
				false)!
			app_secret, app_secret_changed := expand_config_string(app_cfg.app_secret,
				vars, env_map, false)!
			next_apps[name] = FeishuAppConfig{
				app_id:     app_id
				app_secret: app_secret
			}
			if app_id_changed || app_secret_changed {
				changed = true
			}
		}
		cfg.feishu.apps = next_apps.clone()

		// codex
		cfg.codex.url, changed = expand_config_string(cfg.codex.url, vars, env_map, changed)!
		cfg.codex.model, changed = expand_config_string(cfg.codex.model, vars, env_map, changed)!
		cfg.codex.effort, changed = expand_config_string(cfg.codex.effort, vars, env_map, changed)!
		cfg.codex.cwd, changed = expand_config_string(cfg.codex.cwd, vars, env_map, changed)!
		cfg.codex.approval_policy, changed = expand_config_string(cfg.codex.approval_policy, vars, env_map, changed)!
		cfg.codex.sandbox, changed = expand_config_string(cfg.codex.sandbox, vars, env_map, changed)!

		if !changed {
			return
		}
	}
	return error('config variable expansion exceeded max passes (possible cyclic reference)')
}

fn build_config_variable_map(cfg VhttpdConfig) map[string]string {
	mut vars := {
		'server.host':                    cfg.server.host
		'server.port':                    '${cfg.server.port}'
		'files.event_log':                cfg.files.event_log
		'files.pid_file':                 cfg.files.pid_file
		'worker.read_timeout_ms':         '${cfg.worker.read_timeout_ms}'
		'worker.autostart':               '${cfg.worker.autostart}'
		'worker.cmd':                     cfg.worker.cmd
		'worker.restart_backoff_ms':      '${cfg.worker.restart_backoff_ms}'
		'worker.restart_backoff_max_ms':  '${cfg.worker.restart_backoff_max_ms}'
		'worker.max_requests':            '${cfg.worker.max_requests}'
		'worker.socket':                  cfg.worker.socket
		'worker.pool_size':               '${cfg.worker.pool_size}'
		'worker.socket_prefix':           cfg.worker.socket_prefix
		'admin.host':                     cfg.admin.host
		'admin.port':                     '${cfg.admin.port}'
		'admin.token':                    cfg.admin.token
		'assets.enabled':                 '${cfg.assets.enabled}'
		'assets.prefix':                  cfg.assets.prefix
		'assets.root':                    cfg.assets.root
		'assets.cache_control':           cfg.assets.cache_control
		'runtime.timezone':               cfg.runtime.timezone
		'mcp.max_sessions':               '${cfg.mcp.max_sessions}'
		'mcp.max_pending_messages':       '${cfg.mcp.max_pending_messages}'
		'mcp.session_ttl_seconds':        '${cfg.mcp.session_ttl_seconds}'
		'mcp.sampling_capability_policy': cfg.mcp.sampling_capability_policy
		'feishu.enabled':                 '${cfg.feishu.enabled}'
		'feishu.open_base_url':           cfg.feishu.open_base_url
	}
	for name, app_cfg in cfg.feishu.apps {
		vars['feishu.${name}.app_id'] = app_cfg.app_id
		vars['feishu.${name}.app_secret'] = app_cfg.app_secret
	}
	return vars
}

fn expand_config_string(raw string, vars map[string]string, env map[string]string, changed bool) !(string, bool) {
	if !raw.contains('\${') {
		return raw, changed
	}
	mut out := raw
	mut any_change := changed
	for {
		start := out.index('\${') or { break }
		end_rel := out[start + 2..].index('}') or {
			return error('invalid variable expression in config string: missing "}"')
		}
		end := start + 2 + end_rel
		expr := out[start + 2..end].trim_space()
		if expr == '' {
			return error('invalid empty variable expression in config string')
		}
		replacement := resolve_config_variable(expr, vars, env)!
		out = out[..start] + replacement + out[end + 1..]
		any_change = true
	}
	return out, any_change
}

fn resolve_config_variable(expr string, vars map[string]string, env map[string]string) !string {
	mut key := expr
	mut has_default := false
	mut default_raw := ''
	idx := expr.index(':-') or { -1 }
	if idx >= 0 {
		key = expr[..idx].trim_space()
		default_raw = expr[idx + 2..]
		has_default = true
	}
	if key == '' {
		return error('invalid variable expression')
	}
	if key.starts_with('env.') {
		env_key := key.all_after('env.')
		if env_key == '' {
			return error('invalid env variable expression')
		}
		if env_key in env {
			return env[env_key]
		}
		if has_default {
			return default_raw
		}
		return error('missing environment variable "${env_key}"')
	}
	if key in vars {
		return vars[key]
	}
	if has_default {
		return default_raw
	}
	return error('unknown config variable "${key}"')
}
