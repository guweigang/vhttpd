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

struct PathsConfig {
mut:
	root   string = '.'
	values map[string]string
}

struct WorkerConfig {
mut:
	read_timeout_ms        int = 3000 @[toml: 'read_timeout_ms']
	autostart              bool
	cmd                    string
	stream_dispatch        bool @[toml: 'stream_dispatch']
	queue_capacity         int  @[toml: 'queue_capacity']
	queue_timeout_ms       int  @[toml: 'queue_timeout_ms']
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

struct ExecutorConfig {
mut:
	kind string = 'php'
}

struct PhpConfig {
mut:
	bin          string = 'php'
	worker_entry string @[toml: 'worker_entry']
	app_entry    string @[toml: 'app_entry']
	extensions   []string
	args         []string
}

struct VjsxConfig {
mut:
	app_entry       string @[toml: 'app_entry']
	module_root     string @[toml: 'module_root']
	runtime_profile string = 'script' @[toml: 'runtime_profile']
	thread_count    int    = 1    @[toml: 'thread_count']
	max_requests    int    @[toml: 'max_requests']
	enable_fs       bool   @[toml: 'enable_fs']
	enable_process  bool   @[toml: 'enable_process']
	enable_network  bool   @[toml: 'enable_network']
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
	model              string = 'o4-mini' @[toml: 'model']
	effort             string = 'medium' @[toml: 'effort']
	cwd                string
	approval_policy    string = 'never' @[toml: 'approval_policy']
	sandbox            string = 'workspaceWrite' @[toml: 'sandbox']
	reconnect_delay_ms int    = 3000    @[toml: 'reconnect_delay_ms']
	flush_interval_ms  int    = 400    @[toml: 'flush_interval_ms']
}

struct VhttpdConfig {
mut:
	server   ServerConfig
	files    FilesConfig
	paths    PathsConfig
	worker   WorkerConfig
	executor ExecutorConfig
	php      PhpConfig
	vjsx     VjsxConfig
	admin    AdminConfig
	assets   AssetsConfig
	runtime  RuntimeConfig
	mcp      McpConfig
	feishu   FeishuConfig
	codex    CodexConfig
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

fn arg_string_list_or(args []string, key string, default_val []string) []string {
	mut values := []string{}
	for i, a in args {
		if a == key {
			if i + 1 < args.len && !args[i + 1].starts_with('--') {
				for raw in args[i + 1].split(',') {
					value := raw.trim_space()
					if value != '' {
						values << value
					}
				}
			}
			continue
		}
		prefix := '${key}='
		if a.starts_with(prefix) {
			for raw in a.all_after(prefix).split(',') {
				value := raw.trim_space()
				if value != '' {
					values << value
				}
			}
		}
	}
	return if values.len == 0 { default_val } else { values }
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
	decode_paths_config(doc, mut cfg)!
	decode_feishu_config(doc, mut cfg)!
	resolve_config_variables(mut cfg, config_path)!
	return cfg
}

fn decode_paths_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	mut values := map[string]string{}
	if root_any := doc.value_opt('paths') {
		root := root_any.as_map()
		root_value := (root['root'] or { toml.Any('.') }).string()
		if root_value.trim_space() != '' {
			cfg.paths.root = root_value
		}
		for name, value in root {
			if name == 'root' {
				continue
			}
			if value is string || value.str().trim_space() != '' {
				values[name] = value.string()
			}
		}
	}
	cfg.paths.values = values.clone()
}

fn decode_feishu_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	mut apps := map[string]FeishuAppConfig{}
	if root_any := doc.value_opt('feishu') {
		root := root_any.as_map()
		root_app_id := (root['app_id'] or { toml.Any('') }).string()
		root_app_secret := (root['app_secret'] or { toml.Any('') }).string()
		root_verification_token := (root['verification_token'] or { toml.Any('') }).string()
		root_encrypt_key := (root['encrypt_key'] or { toml.Any('') }).string()
		if root_app_id != '' || root_app_secret != '' || root_verification_token != ''
			|| root_encrypt_key != '' {
			apps['main'] = FeishuAppConfig{
				app_id:             root_app_id
				app_secret:         root_app_secret
				verification_token: root_verification_token
				encrypt_key:        root_encrypt_key
			}
		}
		for name, value in root {
			if name in ['enabled', 'open_base_url', 'reconnect_delay_ms',
				'token_refresh_skew_seconds', 'recent_event_limit', 'app_id', 'app_secret',
				'verification_token', 'encrypt_key'] {
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

fn resolve_config_variables(mut cfg VhttpdConfig, config_path string) ! {
	env_map := os.environ()
	max_passes := 12
	for _ in 0 .. max_passes {
		mut changed := false
		vars := build_config_variable_map(cfg)
		cfg.paths.root, changed = expand_config_string(cfg.paths.root, vars, env_map, changed)!
		mut next_paths := map[string]string{}
		for key, value in cfg.paths.values {
			next, c := expand_config_string(value, vars, env_map, false)!
			next_paths[key] = next
			if c {
				changed = true
			}
		}
		cfg.paths.values = next_paths.clone()
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
		cfg.executor.kind, changed = expand_config_string(cfg.executor.kind, vars, env_map,
			changed)!
		cfg.vjsx.app_entry, changed = expand_config_string(cfg.vjsx.app_entry, vars, env_map,
			changed)!
		cfg.vjsx.module_root, changed = expand_config_string(cfg.vjsx.module_root, vars,
			env_map, changed)!
		cfg.vjsx.runtime_profile, changed = expand_config_string(cfg.vjsx.runtime_profile,
			vars, env_map, changed)!
		for i, raw in cfg.worker.sockets {
			next, c := expand_config_string(raw, vars, env_map, false)!
			if c {
			cfg.worker.sockets[i] = next
			changed = true
		}
	}
		cfg.php.bin, changed = expand_config_string(cfg.php.bin, vars, env_map, changed)!
		cfg.php.worker_entry, changed = expand_config_string(cfg.php.worker_entry, vars,
			env_map, changed)!
		cfg.php.app_entry, changed = expand_config_string(cfg.php.app_entry, vars, env_map,
			changed)!
		for i, raw in cfg.php.extensions {
			next, c := expand_config_string(raw, vars, env_map, false)!
			if c {
				cfg.php.extensions[i] = next
				changed = true
			}
		}
		for i, raw in cfg.php.args {
			next, c := expand_config_string(raw, vars, env_map, false)!
			if c {
				cfg.php.args[i] = next
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
		cfg.runtime.timezone, changed = expand_config_string(cfg.runtime.timezone, vars,
			env_map, changed)!
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
		cfg.codex.model, changed = expand_config_string(cfg.codex.model, vars, env_map,
			changed)!
		cfg.codex.effort, changed = expand_config_string(cfg.codex.effort, vars, env_map,
			changed)!
		cfg.codex.cwd, changed = expand_config_string(cfg.codex.cwd, vars, env_map, changed)!
		cfg.codex.approval_policy, changed = expand_config_string(cfg.codex.approval_policy,
			vars, env_map, changed)!
		cfg.codex.sandbox, changed = expand_config_string(cfg.codex.sandbox, vars, env_map,
			changed)!

		if !changed {
			resolve_config_paths(mut cfg, config_path)
			return
		}
	}
	return error('config variable expansion exceeded max passes (possible cyclic reference)')
}

fn resolve_config_base_dir(config_path string) string {
	if config_path.trim_space() == '' {
		return os.getwd()
	}
	return os.dir(os.abs_path(config_path))
}

fn normalize_config_path_value(raw string) string {
	value := raw.trim_space()
	if value.len <= 1 {
		return value
	}
	mut normalized := value
	for normalized.len > 1 && normalized.ends_with('/') {
		normalized = normalized[..normalized.len - 1]
	}
	return normalized
}

fn resolve_config_path(root string, raw string) string {
	value := normalize_config_path_value(raw)
	if value == '' {
		return raw
	}
	if os.is_abs_path(value) {
		return normalize_config_path_value(os.abs_path(value))
	}
	return normalize_config_path_value(os.abs_path(os.join_path(root, value)))
}

fn resolve_config_paths(mut cfg VhttpdConfig, config_path string) {
	base_dir := resolve_config_base_dir(config_path)
	mut root := cfg.paths.root.trim_space()
	if root == '' {
		root = '.'
	}
	cfg.paths.root = resolve_config_path(base_dir, root)
	mut next_paths := map[string]string{}
	for key, value in cfg.paths.values {
		next_paths[key] = resolve_config_path(cfg.paths.root, value)
	}
	cfg.paths.values = next_paths.clone()
	cfg.files.event_log = resolve_config_path(cfg.paths.root, cfg.files.event_log)
	cfg.files.pid_file = resolve_config_path(cfg.paths.root, cfg.files.pid_file)
	cfg.worker.socket = resolve_config_path(cfg.paths.root, cfg.worker.socket)
	cfg.worker.socket_prefix = resolve_config_path(cfg.paths.root, cfg.worker.socket_prefix)
	for i, raw in cfg.worker.sockets {
		cfg.worker.sockets[i] = resolve_config_path(cfg.paths.root, raw)
	}
	if app_entry := cfg.worker.env['VHTTPD_APP'] {
		cfg.worker.env['VHTTPD_APP'] = resolve_config_path(cfg.paths.root, app_entry)
	}
	cfg.php.worker_entry = resolve_config_path(cfg.paths.root, cfg.php.worker_entry)
	cfg.php.app_entry = resolve_config_path(cfg.paths.root, cfg.php.app_entry)
	for i, raw in cfg.php.extensions {
		cfg.php.extensions[i] = resolve_config_path(cfg.paths.root, raw)
	}
	cfg.vjsx.app_entry = resolve_config_path(cfg.paths.root, cfg.vjsx.app_entry)
	cfg.vjsx.module_root = resolve_config_path(cfg.paths.root, cfg.vjsx.module_root)
	cfg.assets.root = resolve_config_path(cfg.paths.root, cfg.assets.root)
	cfg.codex.cwd = resolve_config_path(cfg.paths.root, cfg.codex.cwd)
}

fn build_config_variable_map(cfg VhttpdConfig) map[string]string {
	mut vars := {
		'server.host':                    cfg.server.host
		'server.port':                    '${cfg.server.port}'
		'files.event_log':                cfg.files.event_log
		'files.pid_file':                 cfg.files.pid_file
		'paths.root':                     cfg.paths.root
		'worker.read_timeout_ms':         '${cfg.worker.read_timeout_ms}'
		'worker.autostart':               '${cfg.worker.autostart}'
		'worker.cmd':                     cfg.worker.cmd
		'worker.restart_backoff_ms':      '${cfg.worker.restart_backoff_ms}'
		'worker.restart_backoff_max_ms':  '${cfg.worker.restart_backoff_max_ms}'
		'worker.max_requests':            '${cfg.worker.max_requests}'
		'worker.socket':                  cfg.worker.socket
		'worker.pool_size':               '${cfg.worker.pool_size}'
		'worker.socket_prefix':           cfg.worker.socket_prefix
		'executor.kind':                  cfg.executor.kind
		'php.bin':                        cfg.php.bin
		'php.worker_entry':               cfg.php.worker_entry
		'php.app_entry':                  cfg.php.app_entry
		'vjsx.app_entry':                 cfg.vjsx.app_entry
		'vjsx.module_root':               cfg.vjsx.module_root
		'vjsx.runtime_profile':           cfg.vjsx.runtime_profile
		'vjsx.thread_count':              '${cfg.vjsx.thread_count}'
		'vjsx.max_requests':              '${cfg.vjsx.max_requests}'
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
	for key, value in cfg.paths.values {
		vars['paths.${key}'] = value
	}
	for i, value in cfg.php.extensions {
		vars['php.extensions.${i}'] = value
	}
	for i, value in cfg.php.args {
		vars['php.args.${i}'] = value
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
