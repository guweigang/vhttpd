module config

import os
import toml

pub struct ServerConfig {
pub mut:
	host  string = '127.0.0.1'
	port  int    = 18081
	index string = 'index.php'
	ssl   ServerSslConfig
}

pub struct ServerSslConfig {
pub mut:
	enabled  bool
	cert     string
	cert_key string @[toml: 'cert_key']
}

pub struct FilesConfig {
pub mut:
	event_log string = '/tmp/vhttpd.events.ndjson'
	pid_file  string = '/tmp/vhttpd.pid'
}

pub struct PathsConfig {
pub mut:
	root   string = '.'
	values map[string]string
}

pub struct WorkerConfig {
pub mut:
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

pub struct ExecutorConfig {
pub mut:
	kind string
}

pub struct PhpConfig {
pub mut:
	bin          string = 'php'
	worker_entry string @[toml: 'worker_entry']
	app_entry    string @[toml: 'app_entry']
	extensions   []string
	args         []string
}

pub struct PhpSiteConfig {
pub mut:
	deny_php   []string @[toml: 'deny_php']
	compat_php []string @[toml: 'compat_php']
}

pub struct VjsxConfig {
pub mut:
	app_entry         string   @[toml: 'app_entry']
	module_root       string   @[toml: 'module_root']
	build_root        string   @[toml: 'build_root']
	signature_root    string   @[toml: 'signature_root']
	signature_include []string @[toml: 'signature_include']
	signature_exclude []string @[toml: 'signature_exclude']
	runtime_profile   string = 'script'   @[toml: 'runtime_profile']
	thread_count      int    = 1      @[toml: 'thread_count']
	max_requests      int      @[toml: 'max_requests']
	enable_fs         bool     @[toml: 'enable_fs']
	enable_process    bool     @[toml: 'enable_process']
	enable_network    bool     @[toml: 'enable_network']
}

pub struct PluginConfig {
pub mut:
	kind              string = 'vjsx'
	entry             string
	app_entry         string   @[toml: 'app_entry']
	module_root       string   @[toml: 'module_root']
	build_root        string   @[toml: 'build_root']
	signature_root    string   @[toml: 'signature_root']
	signature_include []string @[toml: 'signature_include']
	signature_exclude []string @[toml: 'signature_exclude']
	runtime_profile   string = 'script'   @[toml: 'runtime_profile']
	thread_count      int    = 1      @[toml: 'thread_count']
	max_requests      int      @[toml: 'max_requests']
	enable_fs         bool     @[toml: 'enable_fs']
	enable_process    bool     @[toml: 'enable_process']
	enable_network    bool     @[toml: 'enable_network']
}

pub struct WebSocketAffinityConfig {
pub mut:
	enabled  bool
	source   string
	key      string
	scope    string
	fallback string
}

pub struct WebSocketActorSourceConfig {
pub mut:
	typ        string @[toml: 'type']
	key        string
	class_name string @[toml: 'class']
}

pub struct WebSocketActorConfig {
pub mut:
	enabled           bool
	sources           []WebSocketActorSourceConfig
	fallback          string
	queue_timeout_ms  int @[toml: 'queue_timeout_ms']
	max_queue_per_key int @[toml: 'max_queue_per_key']
	events            []string
}

pub struct AdminConfig {
pub mut:
	host  string = '127.0.0.1'
	port  int
	token string
}

pub struct AssetsConfig {
pub mut:
	enabled       bool
	prefix        string = '/assets'
	root          string
	cache_control string = 'public, max-age=3600' @[toml: 'cache_control']
}

// AssetsRuntime configures static file serving after config paths are resolved.
pub struct AssetsRuntime {
pub mut:
	enabled       bool
	prefix        string
	root          string
	root_real     string
	cache_control string
}

pub struct RuntimeConfig {
pub mut:
	timezone string = 'Asia/Shanghai'
}

pub struct McpConfig {
pub mut:
	max_sessions               int = 1000      @[toml: 'max_sessions']
	max_pending_messages       int = 128      @[toml: 'max_pending_messages']
	session_ttl_seconds        int = 900      @[toml: 'session_ttl_seconds']
	allowed_origins            []string @[toml: 'allowed_origins']
	sampling_capability_policy string = 'warn'   @[toml: 'sampling_capability_policy']
}

pub struct FeishuConfig {
pub mut:
	enabled                    bool
	open_base_url              string = 'https://open.feishu.cn/open-apis' @[toml: 'open_base_url']
	reconnect_delay_ms         int    = 3000    @[toml: 'reconnect_delay_ms']
	token_refresh_skew_seconds int    = 60    @[toml: 'token_refresh_skew_seconds']
	recent_event_limit         int    = 20    @[toml: 'recent_event_limit']
	apps                       map[string]FeishuAppConfig
	bridge                     BridgeConfig
}

pub struct FeishuAppConfig {
pub mut:
	app_id             string @[toml: 'app_id']
	app_secret         string @[toml: 'app_secret']
	verification_token string @[toml: 'verification_token']
	encrypt_key        string @[toml: 'encrypt_key']
}

pub struct CodexConfig {
pub mut:
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

pub struct OpenAIEndpointsConfig {
pub mut:
	models           bool = true @[toml: 'models']
	chat_completions bool = true @[toml: 'chat_completions']
	responses        bool = true @[toml: 'responses']
	embeddings       bool @[toml: 'embeddings']
}

pub struct OpenAIBackendConfig {
pub mut:
	kind        string = 'openai_http'
	base_url    string @[toml: 'base_url']
	executor    string
	api_key     string @[toml: 'api_key']
	api_key_env string = 'OPENAI_API_KEY' @[toml: 'api_key_env']
	timeout_ms  int    = 60000    @[toml: 'timeout_ms']
}

pub struct OpenAIRouteConfig {
pub mut:
	model          string
	models         []string
	backend        string
	upstream_model string @[toml: 'upstream_model']
}

pub struct OpenAIConfig {
pub mut:
	enabled         bool
	base_path       string = '/v1' @[toml: 'base_path']
	default_backend string @[toml: 'default_backend']
	plugin          string
	endpoints       OpenAIEndpointsConfig
	backends        map[string]OpenAIBackendConfig
	routes          map[string]OpenAIRouteConfig
}

pub struct BridgeConfig {
pub mut:
	enabled   bool
	ws_url    string @[toml: 'ws_url']
	client_id string @[toml: 'client_id']
	token     string
	target_id string @[toml: 'target_id']
}

pub struct DbMysqlConfig {
pub mut:
	host         string = '127.0.0.1'
	port         int    = 3306
	username     string
	password     string
	database     string = 'mysql'
	pool_size    int    = 5      @[toml: 'pool_size']
	idle_ping_ms int      @[toml: 'idle_ping_ms']
	init_sql     []string @[toml: 'init_sql']
}

pub struct DbPgsqlConfig {
pub mut:
	host      string = '127.0.0.1'
	port      int    = 5432
	username  string
	password  string
	database  string = 'postgres'
	pool_size int    = 5 @[toml: 'pool_size']
}

pub struct DbConfig {
pub mut:
	enabled   bool
	socket    string = 'tmp/vhttpd-db.sock'
	driver    string = 'mysql'
	pool_name string = 'default' @[toml: 'pool_name']
	mysql     DbMysqlConfig
	pgsql     DbPgsqlConfig
}

pub struct CacheConfig {
pub mut:
	enabled bool
	socket  string = 'tmp/vhttpd-cache.sock'
}

pub struct RouteMatchConfig {
pub mut:
	method      []string
	path        []string
	path_regexp string @[toml: 'path_regexp']
	query       map[string]string
}

pub struct RouteRuleConfig {
pub mut:
	match                        RouteMatchConfig
	executor                     string
	rewrite                      string
	rewrite_strip_prefix         string @[toml: 'rewrite_strip_prefix']
	root                         string
	cache_control                string            @[toml: 'cache_control']
	response_cache_ttl_ms        int               @[toml: 'response_cache_ttl_ms']
	cache_bypass_cookie_patterns []string          @[toml: 'cache_bypass_cookie_patterns']
	cache_ignore_cookie_patterns []string          @[toml: 'cache_ignore_cookie_patterns']
	response_headers             map[string]string @[toml: 'response_headers']
	max_body_bytes               int               @[toml: 'max_body_bytes']
	required_headers             map[string]string @[toml: 'required_headers']
	denied_query_patterns        map[string]string @[toml: 'denied_query_patterns']
	upload_dir                   string            @[toml: 'upload_dir']
	on_completed                 string            @[toml: 'on_completed']
	status                       int
	location                     string
	body                         string
}

pub struct ExecutorSpecConfig {
pub mut:
	worker   WorkerConfig
	php      PhpConfig
	php_site PhpSiteConfig
	vjsx     VjsxConfig
	executor ExecutorConfig
}

pub struct ListenerConfig {
pub mut:
	host string = '127.0.0.1'
	port int
	site string
	ssl  ServerSslConfig @[skip]
}

pub struct SiteConfig {
pub mut:
	name               string
	project_root       string @[toml: 'project_root']
	document_root      string @[toml: 'document_root']
	default_executor   string @[toml: 'default_executor']
	host               string = '127.0.0.1'
	port               int
	ssl                ServerSslConfig @[skip]
	index              string
	app                string
	worker_entry       string
	paths              PathsConfig
	worker             WorkerConfig
	executor           ExecutorConfig
	php                PhpConfig
	php_site           PhpSiteConfig
	vjsx               VjsxConfig
	plugins            map[string]PluginConfig
	websocket_affinity WebSocketAffinityConfig @[toml: 'websocket_affinity']
	websocket_actor    WebSocketActorConfig    @[toml: 'websocket_actor']
	assets             AssetsConfig
	runtime            RuntimeConfig
	mcp                McpConfig
	feishu             FeishuConfig
	codex              CodexConfig
	openai             OpenAIConfig
	db                 DbConfig
	cache              CacheConfig
	routes             []RouteRuleConfig
	executors          map[string]ExecutorSpecConfig
}

pub struct VhttpdConfig {
pub mut:
	server             ServerConfig
	files              FilesConfig
	paths              PathsConfig
	site               SiteConfig
	worker             WorkerConfig
	executor           ExecutorConfig
	php                PhpConfig
	php_site           PhpSiteConfig
	vjsx               VjsxConfig
	plugins            map[string]PluginConfig
	websocket_affinity WebSocketAffinityConfig @[toml: 'websocket_affinity']
	websocket_actor    WebSocketActorConfig    @[toml: 'websocket_actor']
	admin              AdminConfig
	assets             AssetsConfig
	runtime            RuntimeConfig
	mcp                McpConfig
	feishu             FeishuConfig
	codex              CodexConfig
	openai             OpenAIConfig
	db                 DbConfig
	cache              CacheConfig
	listeners          map[string]ListenerConfig
	sites              map[string]SiteConfig
	config_path        string
	routes             []RouteRuleConfig
	executors          map[string]ExecutorSpecConfig
}

pub fn default_vhttpd_config() VhttpdConfig {
	return VhttpdConfig{}
}

fn config_path_from_args(args []string) string {
	mut config_path := CliArgs.string_or(args, '--config', '')
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
	return config_path
}

pub fn load_vhttpd_config(args []string) !VhttpdConfig {
	config_path := config_path_from_args(args)
	if config_path == '' {
		return default_vhttpd_config()
	}
	text := os.read_file(config_path)!
	version := detect_config_version(text)!
	if version == v2_config_version {
		mut cfg := default_vhttpd_config()
		cfg.config_path = if config_path.trim_space() != '' { os.abs_path(config_path) } else { '' }
		return cfg
	}
	mut cfg := toml.decode[VhttpdConfig](text)!
	doc := toml.parse_text(text)!
	decode_paths_config(doc, mut cfg)!
	decode_feishu_config(doc, mut cfg)!
	decode_openai_root_config(doc, mut cfg)!
	decode_plugins_root_config(doc, mut cfg)!
	decode_root_executors_config(doc, mut cfg)!
	if root_any := doc.value_opt('bridge') {
		root := root_any.as_map()
		if cfg.feishu.bridge.ws_url.trim_space() == ''
			&& cfg.feishu.bridge.client_id.trim_space() == ''
			&& cfg.feishu.bridge.token.trim_space() == ''
			&& cfg.feishu.bridge.target_id.trim_space() == '' && !cfg.feishu.bridge.enabled {
			cfg.feishu.bridge = decode_bridge_config_map(root)
		}
	}
	decode_multi_listener_config(doc, mut cfg)!
	decode_single_site_config(doc, mut cfg)!
	resolve_config_variables(mut cfg, config_path)!
	cfg.config_path = if config_path.trim_space() != '' { os.abs_path(config_path) } else { '' }
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

pub fn decode_feishu_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
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

fn decode_openai_root_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	if root_any := doc.value_opt('openai') {
		root := root_any.as_map()
		cfg.openai = decode_openai_config_map(root)
	}
}

fn decode_plugins_root_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	if root_any := doc.value_opt('plugins') {
		root := root_any.as_map()
		cfg.plugins = decode_plugins_config_map(root)
	}
}

fn decode_root_executors_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	if root_any := doc.value_opt('executors') {
		root := root_any.as_map()
		decoded := decode_executor_spec_config_map_map(root)
		if decoded.len > 0 {
			cfg.executors = decoded.clone()
		}
	}
}

fn toml_string_from_map(entry map[string]toml.Any, key string, default_val string) string {
	return (entry[key] or { toml.Any(default_val) }).string()
}

fn toml_int_from_map(entry map[string]toml.Any, key string, default_val int) int {
	raw_any := entry[key] or { return default_val }
	raw := raw_any.string().trim_space()
	if raw == '' || raw == 'toml.Any()' {
		return default_val
	}
	return raw_any.int()
}

fn toml_bool_from_map(entry map[string]toml.Any, key string, default_val bool) bool {
	raw_any := entry[key] or { return default_val }
	raw := raw_any.string().trim_space()
	if raw == '' || raw == 'toml.Any()' {
		return default_val
	}
	return raw_any.bool()
}

fn toml_string_list_from_map(entry map[string]toml.Any, key string) []string {
	mut values := []string{}
	raw_any := entry[key] or { return values }
	if raw_any is []toml.Any {
		for item in raw_any {
			value := item.string().trim_space()
			if value != '' {
				values << value
			}
		}
	}
	return values
}

fn toml_string_or_list_from_map(entry map[string]toml.Any, key string) []string {
	raw_any := entry[key] or { return []string{} }
	if raw_any is []toml.Any {
		return toml_string_list_from_map(entry, key)
	}
	value := raw_any.string().trim_space()
	if value == '' {
		return []string{}
	}
	return [value]
}

fn toml_string_map_from_map(entry map[string]toml.Any, key string) map[string]string {
	mut values := map[string]string{}
	raw_any := entry[key] or { return values }
	if raw_any is map[string]toml.Any {
		for name, value in raw_any {
			values[name] = value.string()
		}
	}
	return values
}

fn decode_paths_config_map(entry map[string]toml.Any) PathsConfig {
	mut cfg := PathsConfig{}
	if 'root' in entry {
		cfg.root = toml_string_from_map(entry, 'root', cfg.root)
	}
	mut values := map[string]string{}
	for name, value in entry {
		if name == 'root' {
			continue
		}
		values[name] = value.string()
	}
	cfg.values = values.clone()
	return cfg
}

fn decode_worker_config_map(entry map[string]toml.Any) WorkerConfig {
	mut cfg := WorkerConfig{}
	if 'read_timeout_ms' in entry {
		cfg.read_timeout_ms = toml_int_from_map(entry, 'read_timeout_ms', cfg.read_timeout_ms)
	}
	if 'autostart' in entry {
		cfg.autostart = toml_bool_from_map(entry, 'autostart', cfg.autostart)
	}
	if 'cmd' in entry {
		cfg.cmd = toml_string_from_map(entry, 'cmd', cfg.cmd)
	}
	if 'stream_dispatch' in entry {
		cfg.stream_dispatch = toml_bool_from_map(entry, 'stream_dispatch', cfg.stream_dispatch)
	}
	if 'queue_capacity' in entry {
		cfg.queue_capacity = toml_int_from_map(entry, 'queue_capacity', cfg.queue_capacity)
	}
	if 'queue_timeout_ms' in entry {
		cfg.queue_timeout_ms = toml_int_from_map(entry, 'queue_timeout_ms', cfg.queue_timeout_ms)
	}
	if 'restart_backoff_ms' in entry {
		cfg.restart_backoff_ms = toml_int_from_map(entry, 'restart_backoff_ms',
			cfg.restart_backoff_ms)
	}
	if 'restart_backoff_max_ms' in entry {
		cfg.restart_backoff_max_ms = toml_int_from_map(entry, 'restart_backoff_max_ms',
			cfg.restart_backoff_max_ms)
	}
	if 'max_requests' in entry {
		cfg.max_requests = toml_int_from_map(entry, 'max_requests', cfg.max_requests)
	}
	if 'socket' in entry {
		cfg.socket = toml_string_from_map(entry, 'socket', cfg.socket)
	}
	if 'pool_size' in entry {
		cfg.pool_size = toml_int_from_map(entry, 'pool_size', cfg.pool_size)
	}
	if 'websocket_dispatch' in entry {
		cfg.websocket_dispatch = toml_bool_from_map(entry, 'websocket_dispatch',
			cfg.websocket_dispatch)
	}
	if 'socket_prefix' in entry {
		cfg.socket_prefix = toml_string_from_map(entry, 'socket_prefix', cfg.socket_prefix)
	}
	cfg.sockets = toml_string_list_from_map(entry, 'sockets')
	cfg.env = toml_string_map_from_map(entry, 'env')
	return cfg
}

fn decode_executor_config_map(entry map[string]toml.Any) ExecutorConfig {
	mut cfg := ExecutorConfig{}
	if 'kind' in entry {
		cfg.kind = toml_string_from_map(entry, 'kind', cfg.kind)
	}
	return cfg
}

fn decode_php_config_map(entry map[string]toml.Any) PhpConfig {
	mut cfg := PhpConfig{}
	if 'bin' in entry {
		cfg.bin = toml_string_from_map(entry, 'bin', cfg.bin)
	}
	if 'worker_entry' in entry {
		cfg.worker_entry = toml_string_from_map(entry, 'worker_entry', cfg.worker_entry)
	}
	if 'app_entry' in entry {
		cfg.app_entry = toml_string_from_map(entry, 'app_entry', cfg.app_entry)
	}
	cfg.extensions = toml_string_list_from_map(entry, 'extensions')
	cfg.args = toml_string_list_from_map(entry, 'args')
	return cfg
}

fn decode_php_site_config_map(entry map[string]toml.Any) PhpSiteConfig {
	return PhpSiteConfig{
		deny_php:   toml_string_list_from_map(entry, 'deny_php')
		compat_php: toml_string_list_from_map(entry, 'compat_php')
	}
}

fn decode_route_match_config_map(entry map[string]toml.Any) RouteMatchConfig {
	return RouteMatchConfig{
		method:      toml_string_or_list_from_map(entry, 'method')
		path:        toml_string_or_list_from_map(entry, 'path')
		path_regexp: toml_string_from_map(entry, 'path_regexp', '')
		query:       toml_string_map_from_map(entry, 'query')
	}
}

fn decode_route_rule_config_map(entry map[string]toml.Any) RouteRuleConfig {
	mut cfg := RouteRuleConfig{}
	if match_any := entry['match'] {
		if match_any is map[string]toml.Any {
			cfg.match = decode_route_match_config_map(match_any)
		}
	}
	if 'executor' in entry {
		cfg.executor = toml_string_from_map(entry, 'executor', cfg.executor)
	}
	if 'rewrite' in entry {
		cfg.rewrite = toml_string_from_map(entry, 'rewrite', cfg.rewrite)
	}
	if 'rewrite_strip_prefix' in entry {
		cfg.rewrite_strip_prefix = toml_string_from_map(entry, 'rewrite_strip_prefix',
			cfg.rewrite_strip_prefix)
	}
	if 'root' in entry {
		cfg.root = toml_string_from_map(entry, 'root', cfg.root)
	}
	if 'cache_control' in entry {
		cfg.cache_control = toml_string_from_map(entry, 'cache_control', cfg.cache_control)
	}
	if 'response_cache_ttl_ms' in entry {
		cfg.response_cache_ttl_ms = toml_int_from_map(entry, 'response_cache_ttl_ms',
			cfg.response_cache_ttl_ms)
	}
	cfg.cache_bypass_cookie_patterns = toml_string_list_from_map(entry,
		'cache_bypass_cookie_patterns')
	cfg.cache_ignore_cookie_patterns = toml_string_list_from_map(entry,
		'cache_ignore_cookie_patterns')
	cfg.response_headers = toml_string_map_from_map(entry, 'response_headers')
	if 'max_body_bytes' in entry {
		cfg.max_body_bytes = toml_int_from_map(entry, 'max_body_bytes', cfg.max_body_bytes)
	}
	cfg.required_headers = toml_string_map_from_map(entry, 'required_headers')
	cfg.denied_query_patterns = toml_string_map_from_map(entry, 'denied_query_patterns')
	if 'upload_dir' in entry {
		cfg.upload_dir = toml_string_from_map(entry, 'upload_dir', cfg.upload_dir)
	}
	if 'on_completed' in entry {
		cfg.on_completed = toml_string_from_map(entry, 'on_completed', cfg.on_completed)
	}
	if 'status' in entry {
		cfg.status = toml_int_from_map(entry, 'status', cfg.status)
	}
	if 'location' in entry {
		cfg.location = toml_string_from_map(entry, 'location', cfg.location)
	}
	if 'body' in entry {
		cfg.body = toml_string_from_map(entry, 'body', cfg.body)
	}
	return cfg
}

fn decode_route_rule_list(value toml.Any) []RouteRuleConfig {
	mut routes := []RouteRuleConfig{}
	if value is []toml.Any {
		for item in value {
			if item is map[string]toml.Any {
				routes << decode_route_rule_config_map(item)
			}
		}
	}
	return routes
}

fn decode_executor_spec_config_map(entry map[string]toml.Any) ExecutorSpecConfig {
	mut cfg := ExecutorSpecConfig{}
	if 'kind' in entry {
		cfg.executor.kind = toml_string_from_map(entry, 'kind', cfg.executor.kind)
	}
	if cfg.executor.kind == 'vjsx' {
		cfg.vjsx = decode_vjsx_config_map(entry)
	} else if 'bin' in entry || 'worker_entry' in entry || 'app_entry' in entry
		|| 'extensions' in entry || 'args' in entry {
		cfg.php = decode_php_config_map(entry)
	}
	if 'deny_php' in entry || 'compat_php' in entry {
		cfg.php_site = decode_php_site_config_map(entry)
	}
	if worker_any := entry['worker'] {
		if worker_any is map[string]toml.Any {
			cfg.worker = decode_worker_config_map(worker_any)
		}
	}
	if executor_any := entry['executor'] {
		if executor_any is map[string]toml.Any {
			cfg.executor = decode_executor_config_map(executor_any)
		} else {
			cfg.executor.kind = executor_any.string()
		}
	}
	if vjsx_any := entry['vjsx'] {
		if vjsx_any is map[string]toml.Any {
			cfg.vjsx = decode_vjsx_config_map(vjsx_any)
		}
	}
	return cfg
}

fn decode_executor_spec_config_map_map(entry map[string]toml.Any) map[string]ExecutorSpecConfig {
	mut specs := map[string]ExecutorSpecConfig{}
	for name, value in entry {
		if value is map[string]toml.Any {
			specs[name] = decode_executor_spec_config_map(value)
		}
	}
	return specs
}

fn decode_vjsx_config_map(entry map[string]toml.Any) VjsxConfig {
	mut cfg := VjsxConfig{}
	if 'app_entry' in entry {
		cfg.app_entry = toml_string_from_map(entry, 'app_entry', cfg.app_entry)
	}
	if 'module_root' in entry {
		cfg.module_root = toml_string_from_map(entry, 'module_root', cfg.module_root)
	}
	if 'build_root' in entry {
		cfg.build_root = toml_string_from_map(entry, 'build_root', cfg.build_root)
	}
	if 'signature_root' in entry {
		cfg.signature_root = toml_string_from_map(entry, 'signature_root', cfg.signature_root)
	}
	cfg.signature_include = toml_string_list_from_map(entry, 'signature_include')
	cfg.signature_exclude = toml_string_list_from_map(entry, 'signature_exclude')
	if 'runtime_profile' in entry {
		cfg.runtime_profile = toml_string_from_map(entry, 'runtime_profile', cfg.runtime_profile)
	}
	if 'thread_count' in entry {
		cfg.thread_count = toml_int_from_map(entry, 'thread_count', cfg.thread_count)
	}
	if 'max_requests' in entry {
		cfg.max_requests = toml_int_from_map(entry, 'max_requests', cfg.max_requests)
	}
	if 'enable_fs' in entry {
		cfg.enable_fs = toml_bool_from_map(entry, 'enable_fs', cfg.enable_fs)
	}
	if 'enable_process' in entry {
		cfg.enable_process = toml_bool_from_map(entry, 'enable_process', cfg.enable_process)
	}
	if 'enable_network' in entry {
		cfg.enable_network = toml_bool_from_map(entry, 'enable_network', cfg.enable_network)
	}
	return cfg
}

fn decode_plugin_config_map(entry map[string]toml.Any) PluginConfig {
	mut cfg := PluginConfig{}
	if 'kind' in entry {
		cfg.kind = toml_string_from_map(entry, 'kind', cfg.kind)
	}
	if 'entry' in entry {
		cfg.entry = toml_string_from_map(entry, 'entry', cfg.entry)
	}
	if 'app_entry' in entry {
		cfg.app_entry = toml_string_from_map(entry, 'app_entry', cfg.app_entry)
	}
	if cfg.app_entry.trim_space() == '' && cfg.entry.trim_space() != '' {
		cfg.app_entry = cfg.entry
	}
	if 'module_root' in entry {
		cfg.module_root = toml_string_from_map(entry, 'module_root', cfg.module_root)
	}
	if 'build_root' in entry {
		cfg.build_root = toml_string_from_map(entry, 'build_root', cfg.build_root)
	}
	if 'signature_root' in entry {
		cfg.signature_root = toml_string_from_map(entry, 'signature_root', cfg.signature_root)
	}
	cfg.signature_include = toml_string_list_from_map(entry, 'signature_include')
	cfg.signature_exclude = toml_string_list_from_map(entry, 'signature_exclude')
	if 'runtime_profile' in entry {
		cfg.runtime_profile = toml_string_from_map(entry, 'runtime_profile', cfg.runtime_profile)
	}
	if 'thread_count' in entry {
		cfg.thread_count = toml_int_from_map(entry, 'thread_count', cfg.thread_count)
	}
	if 'max_requests' in entry {
		cfg.max_requests = toml_int_from_map(entry, 'max_requests', cfg.max_requests)
	}
	if 'enable_fs' in entry {
		cfg.enable_fs = toml_bool_from_map(entry, 'enable_fs', cfg.enable_fs)
	}
	if 'enable_process' in entry {
		cfg.enable_process = toml_bool_from_map(entry, 'enable_process', cfg.enable_process)
	}
	if 'enable_network' in entry {
		cfg.enable_network = toml_bool_from_map(entry, 'enable_network', cfg.enable_network)
	}
	return cfg
}

fn decode_plugins_config_map(entry map[string]toml.Any) map[string]PluginConfig {
	mut plugins := map[string]PluginConfig{}
	for name, value in entry {
		if value is map[string]toml.Any {
			plugins[name] = decode_plugin_config_map(value)
		}
	}
	return plugins
}

fn decode_websocket_affinity_config_map(entry map[string]toml.Any) WebSocketAffinityConfig {
	mut cfg := WebSocketAffinityConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'source' in entry {
		cfg.source = toml_string_from_map(entry, 'source', cfg.source)
	}
	if 'key' in entry {
		cfg.key = toml_string_from_map(entry, 'key', cfg.key)
	}
	if 'scope' in entry {
		cfg.scope = toml_string_from_map(entry, 'scope', cfg.scope)
	}
	if 'fallback' in entry {
		cfg.fallback = toml_string_from_map(entry, 'fallback', cfg.fallback)
	}
	return cfg
}

fn decode_websocket_actor_source_config(value toml.Any) WebSocketActorSourceConfig {
	if value is map[string]toml.Any {
		return WebSocketActorSourceConfig{
			typ:        toml_string_from_map(value, 'type', '')
			key:        toml_string_from_map(value, 'key', '')
			class_name: toml_string_from_map(value, 'class', '')
		}
	}
	if value.str().trim_space() != '' {
		return WebSocketActorSourceConfig{
			typ: value.str().trim_space()
		}
	}
	return WebSocketActorSourceConfig{}
}

fn decode_websocket_actor_config_map(entry map[string]toml.Any) WebSocketActorConfig {
	mut cfg := WebSocketActorConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'fallback' in entry {
		cfg.fallback = toml_string_from_map(entry, 'fallback', cfg.fallback)
	}
	if 'queue_timeout_ms' in entry {
		cfg.queue_timeout_ms = toml_int_from_map(entry, 'queue_timeout_ms', cfg.queue_timeout_ms)
	}
	if 'max_queue_per_key' in entry {
		cfg.max_queue_per_key = toml_int_from_map(entry, 'max_queue_per_key', cfg.max_queue_per_key)
	}
	cfg.events = toml_string_list_from_map(entry, 'events')
	if sources_any := entry['sources'] {
		if sources_any is []toml.Any {
			mut sources := []WebSocketActorSourceConfig{}
			for source_any in sources_any {
				source := decode_websocket_actor_source_config(source_any)
				if source.typ.trim_space() != '' {
					sources << source
				}
			}
			cfg.sources = sources
		}
	}
	return cfg
}

fn decode_assets_config_map(entry map[string]toml.Any) AssetsConfig {
	mut cfg := AssetsConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'prefix' in entry {
		cfg.prefix = toml_string_from_map(entry, 'prefix', cfg.prefix)
	}
	if 'root' in entry {
		cfg.root = toml_string_from_map(entry, 'root', cfg.root)
	}
	if 'cache_control' in entry {
		cfg.cache_control = toml_string_from_map(entry, 'cache_control', cfg.cache_control)
	}
	return cfg
}

fn decode_runtime_config_map(entry map[string]toml.Any) RuntimeConfig {
	mut cfg := RuntimeConfig{}
	if 'timezone' in entry {
		cfg.timezone = toml_string_from_map(entry, 'timezone', cfg.timezone)
	}
	return cfg
}

fn decode_mcp_config_map(entry map[string]toml.Any) McpConfig {
	mut cfg := McpConfig{}
	if 'max_sessions' in entry {
		cfg.max_sessions = toml_int_from_map(entry, 'max_sessions', cfg.max_sessions)
	}
	if 'max_pending_messages' in entry {
		cfg.max_pending_messages = toml_int_from_map(entry, 'max_pending_messages',
			cfg.max_pending_messages)
	}
	if 'session_ttl_seconds' in entry {
		cfg.session_ttl_seconds = toml_int_from_map(entry, 'session_ttl_seconds',
			cfg.session_ttl_seconds)
	}
	cfg.allowed_origins = toml_string_list_from_map(entry, 'allowed_origins')
	if 'sampling_capability_policy' in entry {
		cfg.sampling_capability_policy = toml_string_from_map(entry, 'sampling_capability_policy',
			cfg.sampling_capability_policy)
	}
	return cfg
}

fn decode_feishu_app_config_map(entry map[string]toml.Any) FeishuAppConfig {
	return FeishuAppConfig{
		app_id:             toml_string_from_map(entry, 'app_id', '')
		app_secret:         toml_string_from_map(entry, 'app_secret', '')
		verification_token: toml_string_from_map(entry, 'verification_token', '')
		encrypt_key:        toml_string_from_map(entry, 'encrypt_key', '')
	}
}

fn decode_feishu_config_map(entry map[string]toml.Any) FeishuConfig {
	mut cfg := FeishuConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'open_base_url' in entry {
		cfg.open_base_url = toml_string_from_map(entry, 'open_base_url', cfg.open_base_url)
	}
	if 'reconnect_delay_ms' in entry {
		cfg.reconnect_delay_ms = toml_int_from_map(entry, 'reconnect_delay_ms',
			cfg.reconnect_delay_ms)
	}
	if 'token_refresh_skew_seconds' in entry {
		cfg.token_refresh_skew_seconds = toml_int_from_map(entry, 'token_refresh_skew_seconds',
			cfg.token_refresh_skew_seconds)
	}
	if 'recent_event_limit' in entry {
		cfg.recent_event_limit = toml_int_from_map(entry, 'recent_event_limit',
			cfg.recent_event_limit)
	}
	mut apps := map[string]FeishuAppConfig{}
	root_app := decode_feishu_app_config_map(entry)
	if root_app.app_id != '' || root_app.app_secret != '' || root_app.verification_token != ''
		|| root_app.encrypt_key != '' {
		apps['main'] = root_app
	}
	for name, value in entry {
		if name in ['enabled', 'open_base_url', 'reconnect_delay_ms', 'token_refresh_skew_seconds',
			'recent_event_limit', 'app_id', 'app_secret', 'verification_token', 'encrypt_key'] {
			continue
		}
		if value is map[string]toml.Any {
			app_cfg := decode_feishu_app_config_map(value)
			if app_cfg.app_id == '' && app_cfg.app_secret == '' && app_cfg.verification_token == ''
				&& app_cfg.encrypt_key == '' {
				continue
			}
			apps[name] = app_cfg
		}
	}
	cfg.apps = apps.clone()
	if bridge_any := entry['bridge'] {
		if bridge_any is map[string]toml.Any {
			cfg.bridge = decode_bridge_config_map(bridge_any)
		}
	}
	return cfg
}

fn decode_codex_config_map(entry map[string]toml.Any) CodexConfig {
	mut cfg := CodexConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'url' in entry {
		cfg.url = toml_string_from_map(entry, 'url', cfg.url)
	}
	if 'model' in entry {
		cfg.model = toml_string_from_map(entry, 'model', cfg.model)
	}
	if 'effort' in entry {
		cfg.effort = toml_string_from_map(entry, 'effort', cfg.effort)
	}
	if 'cwd' in entry {
		cfg.cwd = toml_string_from_map(entry, 'cwd', cfg.cwd)
	}
	if 'approval_policy' in entry {
		cfg.approval_policy = toml_string_from_map(entry, 'approval_policy', cfg.approval_policy)
	}
	if 'sandbox' in entry {
		cfg.sandbox = toml_string_from_map(entry, 'sandbox', cfg.sandbox)
	}
	if 'reconnect_delay_ms' in entry {
		cfg.reconnect_delay_ms = toml_int_from_map(entry, 'reconnect_delay_ms',
			cfg.reconnect_delay_ms)
	}
	if 'flush_interval_ms' in entry {
		cfg.flush_interval_ms = toml_int_from_map(entry, 'flush_interval_ms', cfg.flush_interval_ms)
	}
	return cfg
}

fn decode_openai_endpoints_config_map(entry map[string]toml.Any) OpenAIEndpointsConfig {
	mut cfg := OpenAIEndpointsConfig{}
	if 'models' in entry {
		cfg.models = toml_bool_from_map(entry, 'models', cfg.models)
	}
	if 'chat_completions' in entry {
		cfg.chat_completions = toml_bool_from_map(entry, 'chat_completions', cfg.chat_completions)
	}
	if 'responses' in entry {
		cfg.responses = toml_bool_from_map(entry, 'responses', cfg.responses)
	}
	if 'embeddings' in entry {
		cfg.embeddings = toml_bool_from_map(entry, 'embeddings', cfg.embeddings)
	}
	return cfg
}

fn decode_openai_backend_config_map(entry map[string]toml.Any) OpenAIBackendConfig {
	mut cfg := OpenAIBackendConfig{}
	if 'kind' in entry {
		cfg.kind = toml_string_from_map(entry, 'kind', cfg.kind)
	}
	if 'base_url' in entry {
		cfg.base_url = toml_string_from_map(entry, 'base_url', cfg.base_url)
	}
	if 'executor' in entry {
		cfg.executor = toml_string_from_map(entry, 'executor', cfg.executor)
	}
	if 'api_key' in entry {
		cfg.api_key = toml_string_from_map(entry, 'api_key', cfg.api_key)
	}
	if 'api_key_env' in entry {
		cfg.api_key_env = toml_string_from_map(entry, 'api_key_env', cfg.api_key_env)
	}
	if 'timeout_ms' in entry {
		cfg.timeout_ms = toml_int_from_map(entry, 'timeout_ms', cfg.timeout_ms)
	}
	return cfg
}

fn decode_openai_route_config_map(entry map[string]toml.Any) OpenAIRouteConfig {
	mut cfg := OpenAIRouteConfig{}
	if 'model' in entry {
		cfg.model = toml_string_from_map(entry, 'model', cfg.model)
	}
	cfg.models = toml_string_list_from_map(entry, 'models')
	if 'backend' in entry {
		cfg.backend = toml_string_from_map(entry, 'backend', cfg.backend)
	}
	if 'upstream_model' in entry {
		cfg.upstream_model = toml_string_from_map(entry, 'upstream_model', cfg.upstream_model)
	}
	return cfg
}

fn decode_openai_config_map(entry map[string]toml.Any) OpenAIConfig {
	mut cfg := OpenAIConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'base_path' in entry {
		cfg.base_path = toml_string_from_map(entry, 'base_path', cfg.base_path)
	}
	if 'default_backend' in entry {
		cfg.default_backend = toml_string_from_map(entry, 'default_backend', cfg.default_backend)
	}
	if 'plugin' in entry {
		cfg.plugin = toml_string_from_map(entry, 'plugin', cfg.plugin)
	}
	if endpoints_any := entry['endpoints'] {
		if endpoints_any is map[string]toml.Any {
			cfg.endpoints = decode_openai_endpoints_config_map(endpoints_any)
		}
	}
	mut backends := map[string]OpenAIBackendConfig{}
	if backends_any := entry['backends'] {
		if backends_any is map[string]toml.Any {
			for name, value in backends_any {
				if value is map[string]toml.Any {
					backends[name] = decode_openai_backend_config_map(value)
				}
			}
		}
	}
	cfg.backends = backends.clone()
	mut routes := map[string]OpenAIRouteConfig{}
	if routes_any := entry['routes'] {
		if routes_any is map[string]toml.Any {
			for name, value in routes_any {
				if value is map[string]toml.Any {
					mut route := decode_openai_route_config_map(value)
					if route.model.trim_space() == '' {
						route.model = name
					}
					if route.models.len == 0 && route.model.trim_space() != '' {
						route.models = [route.model]
					}
					routes[name] = route
				}
			}
		}
	}
	cfg.routes = routes.clone()
	return cfg
}

fn decode_bridge_config_map(entry map[string]toml.Any) BridgeConfig {
	mut cfg := BridgeConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'ws_url' in entry {
		cfg.ws_url = toml_string_from_map(entry, 'ws_url', cfg.ws_url)
	}
	if 'client_id' in entry {
		cfg.client_id = toml_string_from_map(entry, 'client_id', cfg.client_id)
	}
	if 'token' in entry {
		cfg.token = toml_string_from_map(entry, 'token', cfg.token)
	}
	if 'target_id' in entry {
		cfg.target_id = toml_string_from_map(entry, 'target_id', cfg.target_id)
	}
	return cfg
}

fn decode_listener_config_map(entry map[string]toml.Any) ListenerConfig {
	mut cfg := ListenerConfig{}
	if 'host' in entry {
		cfg.host = toml_string_from_map(entry, 'host', cfg.host)
	}
	if 'port' in entry {
		cfg.port = toml_int_from_map(entry, 'port', cfg.port)
	}
	if 'site' in entry {
		cfg.site = toml_string_from_map(entry, 'site', cfg.site)
	}
	if 'ssl' in entry {
		if ssl_any := entry['ssl'] {
			if ssl_any is map[string]toml.Any {
				cfg.ssl = decode_server_ssl_config_map(ssl_any)
			}
		}
	}
	return cfg
}

fn decode_server_ssl_config_map(entry map[string]toml.Any) ServerSslConfig {
	mut cfg := ServerSslConfig{}
	if 'enabled' in entry {
		cfg.enabled = toml_bool_from_map(entry, 'enabled', cfg.enabled)
	}
	if 'cert' in entry {
		cfg.cert = toml_string_from_map(entry, 'cert', cfg.cert)
	}
	if 'cert_key' in entry {
		cfg.cert_key = toml_string_from_map(entry, 'cert_key', cfg.cert_key)
	}
	return cfg
}

fn decode_site_config_map(entry map[string]toml.Any) SiteConfig {
	mut cfg := SiteConfig{}
	if 'name' in entry {
		cfg.name = toml_string_from_map(entry, 'name', cfg.name)
	}
	if 'root' in entry {
		cfg.project_root = toml_string_from_map(entry, 'root', cfg.project_root)
	}
	if 'project_root' in entry {
		cfg.project_root = toml_string_from_map(entry, 'project_root', cfg.project_root)
	}
	if 'document_root' in entry {
		cfg.document_root = toml_string_from_map(entry, 'document_root', cfg.document_root)
	}
	if 'default_executor' in entry {
		cfg.default_executor = toml_string_from_map(entry, 'default_executor', cfg.default_executor)
	}
	if 'host' in entry {
		cfg.host = toml_string_from_map(entry, 'host', cfg.host)
	}
	if 'port' in entry {
		cfg.port = toml_int_from_map(entry, 'port', cfg.port)
	}
	if 'ssl' in entry {
		if ssl_any := entry['ssl'] {
			if ssl_any is map[string]toml.Any {
				cfg.ssl = decode_server_ssl_config_map(ssl_any)
			}
		}
	}
	if 'index' in entry {
		cfg.index = toml_string_from_map(entry, 'index', cfg.index)
	}
	if 'app' in entry {
		cfg.app = toml_string_from_map(entry, 'app', cfg.app)
	}
	if paths_any := entry['paths'] {
		if paths_any is map[string]toml.Any {
			cfg.paths = decode_paths_config_map(paths_any)
		}
	}
	if worker_any := entry['worker'] {
		if worker_any is map[string]toml.Any {
			cfg.worker = decode_worker_config_map(worker_any)
			if 'entry' in worker_any {
				cfg.worker_entry = toml_string_from_map(worker_any, 'entry', cfg.worker_entry)
			}
		}
	}
	if executor_any := entry['executor'] {
		if executor_any is map[string]toml.Any {
			cfg.executor = decode_executor_config_map(executor_any)
		} else {
			cfg.executor.kind = executor_any.string()
		}
	}
	if php_any := entry['php'] {
		if php_any is map[string]toml.Any {
			cfg.php = decode_php_config_map(php_any)
		}
	}
	if vjsx_any := entry['vjsx'] {
		if vjsx_any is map[string]toml.Any {
			cfg.vjsx = decode_vjsx_config_map(vjsx_any)
		}
	}
	if plugins_any := entry['plugins'] {
		if plugins_any is map[string]toml.Any {
			cfg.plugins = decode_plugins_config_map(plugins_any)
		}
	}
	if websocket_affinity_any := entry['websocket_affinity'] {
		if websocket_affinity_any is map[string]toml.Any {
			cfg.websocket_affinity = decode_websocket_affinity_config_map(websocket_affinity_any)
		}
	}
	if websocket_actor_any := entry['websocket_actor'] {
		if websocket_actor_any is map[string]toml.Any {
			cfg.websocket_actor = decode_websocket_actor_config_map(websocket_actor_any)
		}
	}
	if assets_any := entry['assets'] {
		if assets_any is map[string]toml.Any {
			cfg.assets = decode_assets_config_map(assets_any)
		}
	}
	if runtime_any := entry['runtime'] {
		if runtime_any is map[string]toml.Any {
			cfg.runtime = decode_runtime_config_map(runtime_any)
		}
	}
	if mcp_any := entry['mcp'] {
		if mcp_any is map[string]toml.Any {
			cfg.mcp = decode_mcp_config_map(mcp_any)
		}
	}
	if feishu_any := entry['feishu'] {
		if feishu_any is map[string]toml.Any {
			cfg.feishu = decode_feishu_config_map(feishu_any)
		}
	}
	if codex_any := entry['codex'] {
		if codex_any is map[string]toml.Any {
			cfg.codex = decode_codex_config_map(codex_any)
		}
	}
	if openai_any := entry['openai'] {
		if openai_any is map[string]toml.Any {
			cfg.openai = decode_openai_config_map(openai_any)
		}
	}
	if routes_any := entry['routes'] {
		cfg.routes = decode_route_rule_list(routes_any)
	}
	if executors_any := entry['executors'] {
		if executors_any is map[string]toml.Any {
			cfg.executors = decode_executor_spec_config_map_map(executors_any)
		}
	}
	return cfg
}

fn decode_multi_listener_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	mut listeners := map[string]ListenerConfig{}
	if root_any := doc.value_opt('listeners') {
		root := root_any.as_map()
		for name, value in root {
			if value is map[string]toml.Any {
				listeners[name] = decode_listener_config_map(value)
			}
		}
	}
	if listeners.len > 0 {
		cfg.listeners = listeners.clone()
	}
	mut sites := map[string]SiteConfig{}
	if root_any := doc.value_opt('sites') {
		root := root_any.as_map()
		for name, value in root {
			if value is map[string]toml.Any {
				sites[name] = decode_site_config_map(value)
			}
		}
	}
	if sites.len > 0 {
		cfg.sites = sites.clone()
	}
}

fn decode_single_site_config(doc toml.Doc, mut cfg VhttpdConfig) ! {
	if root_any := doc.value_opt('site') {
		root := root_any.as_map()
		single_site_root := toml_string_from_map(root, 'root', '')
		cfg.site = decode_site_config_map(root)
		if single_site_root.trim_space() != '' {
			cfg.site.document_root = single_site_root
			cfg.site.project_root = ''
		}
		if cfg.site.project_root.trim_space() != '' {
			cfg.paths.root = cfg.site.project_root
		}
		if cfg.site.index.trim_space() != '' {
			cfg.server.index = cfg.site.index
		}
		if cfg.site.document_root.trim_space() != '' && cfg.worker.env['DOCUMENT_ROOT'] == '' {
			cfg.worker.env['DOCUMENT_ROOT'] = cfg.site.document_root
		}
		cfg = cfg.with_site(cfg.site)
	}
}

pub fn resolve_config_variables(mut cfg VhttpdConfig, config_path string) ! {
	env_map := os.environ()
	base_dir := resolve_config_base_dir(config_path)
	max_passes := 12
	for _ in 0 .. max_passes {
		mut changed := false
		mut vars := build_config_variable_map(cfg)
		cfg.paths.root, changed = expand_config_string(cfg.paths.root, 'paths', vars, env_map,
			changed)!
		vars['paths.root'] = resolve_config_path(base_dir, cfg.paths.root)
		cfg.site.document_root, changed = expand_config_string(cfg.site.document_root, 'site',
			vars, env_map, changed)!
		if cfg.site.document_root.trim_space() != '' {
			vars['site.root'] = resolve_config_path(vars['paths.root'], cfg.site.document_root)
		}
		mut next_paths := map[string]string{}
		for key, value in cfg.paths.values {
			next, c := expand_config_string(value, 'paths', vars, env_map, false)!
			next_paths[key] = next
			if c {
				changed = true
			}
		}
		cfg.paths.values = next_paths.clone()
		cfg.server.host, changed = expand_config_string(cfg.server.host, 'server', vars, env_map,
			changed)!
		cfg.server.ssl.cert, changed = expand_config_string(cfg.server.ssl.cert, 'server.ssl',
			vars, env_map, changed)!
		cfg.server.ssl.cert_key, changed = expand_config_string(cfg.server.ssl.cert_key,
			'server.ssl', vars, env_map, changed)!
		for name, mut listener in cfg.listeners {
			listener.ssl.cert, changed = expand_config_string(listener.ssl.cert,
				'listeners.${name}.ssl', vars, env_map, changed)!
			listener.ssl.cert_key, changed = expand_config_string(listener.ssl.cert_key,
				'listeners.${name}.ssl', vars, env_map, changed)!
			cfg.listeners[name] = listener
		}
		for name, mut site in cfg.sites {
			site.ssl.cert, changed = expand_config_string(site.ssl.cert, 'sites.${name}.ssl', vars,
				env_map, changed)!
			site.ssl.cert_key, changed = expand_config_string(site.ssl.cert_key,
				'sites.${name}.ssl', vars, env_map, changed)!
			cfg.sites[name] = site
		}
		cfg.files.event_log, changed = expand_config_string(cfg.files.event_log, 'files', vars,
			env_map, changed)!
		cfg.files.pid_file, changed = expand_config_string(cfg.files.pid_file, 'files', vars,
			env_map, changed)!
		cfg.db.socket, changed = expand_config_string(cfg.db.socket, 'db', vars, env_map, changed)!
		cfg.db.driver, changed = expand_config_string(cfg.db.driver, 'db', vars, env_map, changed)!
		cfg.db.pool_name, changed = expand_config_string(cfg.db.pool_name, 'db', vars, env_map,
			changed)!
		cfg.db.mysql.host, changed = expand_config_string(cfg.db.mysql.host, 'db.mysql', vars,
			env_map, changed)!
		cfg.db.mysql.username, changed = expand_config_string(cfg.db.mysql.username, 'db.mysql',
			vars, env_map, changed)!
		cfg.db.mysql.password, changed = expand_config_string(cfg.db.mysql.password, 'db.mysql',
			vars, env_map, changed)!
		cfg.db.mysql.database, changed = expand_config_string(cfg.db.mysql.database, 'db.mysql',
			vars, env_map, changed)!
		cfg.db.pgsql.host, changed = expand_config_string(cfg.db.pgsql.host, 'db.pgsql', vars,
			env_map, changed)!
		cfg.db.pgsql.username, changed = expand_config_string(cfg.db.pgsql.username, 'db.pgsql',
			vars, env_map, changed)!
		cfg.db.pgsql.password, changed = expand_config_string(cfg.db.pgsql.password, 'db.pgsql',
			vars, env_map, changed)!
		cfg.db.pgsql.database, changed = expand_config_string(cfg.db.pgsql.database, 'db.pgsql',
			vars, env_map, changed)!
		cfg.cache.socket, changed = expand_config_string(cfg.cache.socket, 'cache', vars, env_map,
			changed)!
		cfg.worker.cmd, changed = expand_config_string(cfg.worker.cmd, 'worker', vars, env_map,
			changed)!
		cfg.worker.socket, changed = expand_config_string(cfg.worker.socket, 'worker', vars,
			env_map, changed)!
		cfg.worker.socket_prefix, changed = expand_config_string(cfg.worker.socket_prefix,
			'worker', vars, env_map, changed)!
		cfg.executor.kind, changed = expand_config_string(cfg.executor.kind, 'executor', vars,
			env_map, changed)!
		cfg.vjsx.app_entry, changed = expand_config_string(cfg.vjsx.app_entry, 'vjsx', vars,
			env_map, changed)!
		cfg.vjsx.module_root, changed = expand_config_string(cfg.vjsx.module_root, 'vjsx', vars,
			env_map, changed)!
		cfg.vjsx.build_root, changed = expand_config_string(cfg.vjsx.build_root, 'vjsx', vars,
			env_map, changed)!
		cfg.vjsx.signature_root, changed = expand_config_string(cfg.vjsx.signature_root, 'vjsx',
			vars, env_map, changed)!
		cfg.vjsx.runtime_profile, changed = expand_config_string(cfg.vjsx.runtime_profile, 'vjsx',
			vars, env_map, changed)!
		for i, raw in cfg.vjsx.signature_include {
			next, c := expand_config_string(raw, 'vjsx', vars, env_map, false)!
			if c {
				cfg.vjsx.signature_include[i] = next
				changed = true
			}
		}
		for i, raw in cfg.vjsx.signature_exclude {
			next, c := expand_config_string(raw, 'vjsx', vars, env_map, false)!
			if c {
				cfg.vjsx.signature_exclude[i] = next
				changed = true
			}
		}
		mut next_plugins := map[string]PluginConfig{}
		for name, plugin in cfg.plugins {
			entry, entry_changed := expand_config_string(plugin.entry, 'plugins.${name}', vars,
				env_map, false)!
			app_entry, app_entry_changed := expand_config_string(plugin.app_entry,
				'plugins.${name}', vars, env_map, false)!
			module_root, module_root_changed := expand_config_string(plugin.module_root,
				'plugins.${name}', vars, env_map, false)!
			build_root, build_root_changed := expand_config_string(plugin.build_root,
				'plugins.${name}', vars, env_map, false)!
			signature_root, signature_root_changed := expand_config_string(plugin.signature_root,
				'plugins.${name}', vars, env_map, false)!
			runtime_profile, runtime_profile_changed := expand_config_string(plugin.runtime_profile,
				'plugins.${name}', vars, env_map, false)!
			mut signature_include := plugin.signature_include.clone()
			for i, raw in signature_include {
				next, c := expand_config_string(raw, 'plugins.${name}', vars, env_map, false)!
				if c {
					signature_include[i] = next
					changed = true
				}
			}
			mut signature_exclude := plugin.signature_exclude.clone()
			for i, raw in signature_exclude {
				next, c := expand_config_string(raw, 'plugins.${name}', vars, env_map, false)!
				if c {
					signature_exclude[i] = next
					changed = true
				}
			}
			next_plugins[name] = PluginConfig{
				kind:              plugin.kind
				entry:             entry
				app_entry:         app_entry
				module_root:       module_root
				build_root:        build_root
				signature_root:    signature_root
				signature_include: signature_include
				signature_exclude: signature_exclude
				runtime_profile:   runtime_profile
				thread_count:      plugin.thread_count
				max_requests:      plugin.max_requests
				enable_fs:         plugin.enable_fs
				enable_process:    plugin.enable_process
				enable_network:    plugin.enable_network
			}
			if entry_changed || app_entry_changed || module_root_changed || build_root_changed
				|| signature_root_changed || runtime_profile_changed {
				changed = true
			}
		}
		cfg.plugins = next_plugins.clone()
		for i, raw in cfg.worker.sockets {
			next, c := expand_config_string(raw, 'worker', vars, env_map, false)!
			if c {
				cfg.worker.sockets[i] = next
				changed = true
			}
		}
		cfg.php.bin, changed = expand_config_string(cfg.php.bin, 'php', vars, env_map, changed)!
		cfg.php.worker_entry, changed = expand_config_string(cfg.php.worker_entry, 'php', vars,
			env_map, changed)!
		cfg.php.app_entry, changed = expand_config_string(cfg.php.app_entry, 'php', vars, env_map,
			changed)!
		for i, raw in cfg.php.extensions {
			next, c := expand_config_string(raw, 'php', vars, env_map, false)!
			if c {
				cfg.php.extensions[i] = next
				changed = true
			}
		}
		for i, raw in cfg.php.args {
			next, c := expand_config_string(raw, 'php', vars, env_map, false)!
			if c {
				cfg.php.args[i] = next
				changed = true
			}
		}
		for i, raw in cfg.php_site.deny_php {
			next, c := expand_config_string(raw, 'site.php', vars, env_map, false)!
			if c {
				cfg.php_site.deny_php[i] = next
				changed = true
			}
		}
		for i, raw in cfg.php_site.compat_php {
			next, c := expand_config_string(raw, 'site.php', vars, env_map, false)!
			if c {
				cfg.php_site.compat_php[i] = next
				changed = true
			}
		}
		mut next_env := map[string]string{}
		for key, value in cfg.worker.env {
			next, c := expand_config_string(value, 'worker', vars, env_map, false)!
			next_env[key] = next
			if c {
				changed = true
			}
		}
		cfg.worker.env = next_env.clone()
		cfg.admin.host, changed = expand_config_string(cfg.admin.host, 'admin', vars, env_map,
			changed)!
		cfg.admin.token, changed = expand_config_string(cfg.admin.token, 'admin', vars, env_map,
			changed)!
		cfg.assets.prefix, changed = expand_config_string(cfg.assets.prefix, 'assets', vars,
			env_map, changed)!
		cfg.assets.root, changed = expand_config_string(cfg.assets.root, 'assets', vars, env_map,
			changed)!
		cfg.assets.cache_control, changed = expand_config_string(cfg.assets.cache_control,
			'assets', vars, env_map, changed)!
		cfg.runtime.timezone, changed = expand_config_string(cfg.runtime.timezone, 'runtime', vars,
			env_map, changed)!
		cfg.feishu.open_base_url, changed = expand_config_string(cfg.feishu.open_base_url,
			'feishu', vars, env_map, changed)!
		mut next_apps := map[string]FeishuAppConfig{}
		for name, app_cfg in cfg.feishu.apps {
			app_id, app_id_changed := expand_config_string(app_cfg.app_id, 'feishu.${name}', vars,
				env_map, false)!
			app_secret, app_secret_changed := expand_config_string(app_cfg.app_secret,
				'feishu.${name}', vars, env_map, false)!
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
		cfg.codex.url, changed = expand_config_string(cfg.codex.url, 'codex', vars, env_map,
			changed)!
		cfg.codex.model, changed = expand_config_string(cfg.codex.model, 'codex', vars, env_map,
			changed)!
		cfg.codex.effort, changed = expand_config_string(cfg.codex.effort, 'codex', vars, env_map,
			changed)!
		cfg.codex.cwd, changed = expand_config_string(cfg.codex.cwd, 'codex', vars, env_map,
			changed)!
		cfg.codex.approval_policy, changed = expand_config_string(cfg.codex.approval_policy,
			'codex', vars, env_map, changed)!
		cfg.codex.sandbox, changed = expand_config_string(cfg.codex.sandbox, 'codex', vars,
			env_map, changed)!
		cfg.openai.base_path, changed = expand_config_string(cfg.openai.base_path, 'openai', vars,
			env_map, changed)!
		cfg.openai.default_backend, changed = expand_config_string(cfg.openai.default_backend,
			'openai', vars, env_map, changed)!
		cfg.openai.plugin, changed = expand_config_string(cfg.openai.plugin, 'openai', vars,
			env_map, changed)!
		mut next_openai_backends := map[string]OpenAIBackendConfig{}
		for name, backend in cfg.openai.backends {
			base_url, base_url_changed := expand_config_string(backend.base_url,
				'openai.backends.${name}', vars, env_map, false)!
			api_key, api_key_changed := expand_config_string(backend.api_key,
				'openai.backends.${name}', vars, env_map, false)!
			executor, executor_changed := expand_config_string(backend.executor,
				'openai.backends.${name}', vars, env_map, false)!
			api_key_env, api_key_env_changed := expand_config_string(backend.api_key_env,
				'openai.backends.${name}', vars, env_map, false)!
			next_openai_backends[name] = OpenAIBackendConfig{
				kind:        backend.kind
				base_url:    base_url
				executor:    executor
				api_key:     api_key
				api_key_env: api_key_env
				timeout_ms:  backend.timeout_ms
			}
			if base_url_changed || executor_changed || api_key_changed || api_key_env_changed {
				changed = true
			}
		}
		cfg.openai.backends = next_openai_backends.clone()
		mut next_openai_routes := map[string]OpenAIRouteConfig{}
		for name, route in cfg.openai.routes {
			model, model_changed := expand_config_string(route.model, 'openai.routes.${name}',
				vars, env_map, false)!
			backend, backend_changed := expand_config_string(route.backend,
				'openai.routes.${name}', vars, env_map, false)!
			upstream_model, upstream_model_changed := expand_config_string(route.upstream_model,
				'openai.routes.${name}', vars, env_map, false)!
			mut models := route.models.clone()
			for i, raw in models {
				next, c := expand_config_string(raw, 'openai.routes.${name}', vars, env_map, false)!
				if c {
					models[i] = next
					changed = true
				}
			}
			next_openai_routes[name] = OpenAIRouteConfig{
				model:          model
				models:         models
				backend:        backend
				upstream_model: upstream_model
			}
			if model_changed || backend_changed || upstream_model_changed {
				changed = true
			}
		}
		cfg.openai.routes = next_openai_routes.clone()
		cfg.feishu.bridge.ws_url, changed = expand_config_string(cfg.feishu.bridge.ws_url,
			'feishu.bridge', vars, env_map, changed)!
		cfg.feishu.bridge.client_id, changed = expand_config_string(cfg.feishu.bridge.client_id,
			'feishu.bridge', vars, env_map, changed)!
		cfg.feishu.bridge.token, changed = expand_config_string(cfg.feishu.bridge.token,
			'feishu.bridge', vars, env_map, changed)!
		cfg.feishu.bridge.target_id, changed = expand_config_string(cfg.feishu.bridge.target_id,
			'feishu.bridge', vars, env_map, changed)!

		cfg.feishu.bridge.target_id, changed = expand_config_string(cfg.feishu.bridge.target_id,
			'feishu.bridge', vars, env_map, changed)!

		// 展开 routes
		mut next_routes := []RouteRuleConfig{}
		for r in cfg.routes {
			mut r_copy := r
			root, root_changed := expand_config_string(r.root, 'routes', vars, env_map, false)!
			if root_changed {
				r_copy.root = root
				changed = true
			}
			cache_control, cache_control_changed := expand_config_string(r.cache_control, 'routes',
				vars, env_map, false)!
			if cache_control_changed {
				r_copy.cache_control = cache_control
				changed = true
			}
			mut cache_bypass_cookie_patterns := []string{}
			for item in r.cache_bypass_cookie_patterns {
				expanded, item_changed :=
					expand_config_string(item, 'routes', vars, env_map, false)!
				cache_bypass_cookie_patterns << expanded
				if item_changed {
					changed = true
				}
			}
			r_copy.cache_bypass_cookie_patterns = cache_bypass_cookie_patterns
			mut cache_ignore_cookie_patterns := []string{}
			for item in r.cache_ignore_cookie_patterns {
				expanded, item_changed :=
					expand_config_string(item, 'routes', vars, env_map, false)!
				cache_ignore_cookie_patterns << expanded
				if item_changed {
					changed = true
				}
			}
			r_copy.cache_ignore_cookie_patterns = cache_ignore_cookie_patterns
			mut response_headers := map[string]string{}
			for header_name, header_value in r.response_headers {
				expanded, item_changed := expand_config_string(header_value, 'routes', vars,
					env_map, false)!
				response_headers[header_name] = expanded
				if item_changed {
					changed = true
				}
			}
			r_copy.response_headers = response_headers.clone()
			mut required_headers := map[string]string{}
			for header_name, header_value in r.required_headers {
				expanded, item_changed := expand_config_string(header_value, 'routes', vars,
					env_map, false)!
				required_headers[header_name] = expanded
				if item_changed {
					changed = true
				}
			}
			r_copy.required_headers = required_headers.clone()
			mut denied_query_patterns := map[string]string{}
			for query_name, query_value in r.denied_query_patterns {
				expanded, item_changed := expand_config_string(query_value, 'routes', vars,
					env_map, false)!
				denied_query_patterns[query_name] = expanded
				if item_changed {
					changed = true
				}
			}
			r_copy.denied_query_patterns = denied_query_patterns.clone()
			upload_dir, upload_dir_changed := expand_config_string(r.upload_dir, 'routes', vars,
				env_map, false)!
			if upload_dir_changed {
				r_copy.upload_dir = upload_dir
				changed = true
			}
			on_completed, on_completed_changed := expand_config_string(r.on_completed, 'routes',
				vars, env_map, false)!
			if on_completed_changed {
				r_copy.on_completed = on_completed
				changed = true
			}
			executor, executor_changed := expand_config_string(r.executor, 'routes', vars, env_map,
				false)!
			if executor_changed {
				r_copy.executor = executor
				changed = true
			}
			rewrite, rewrite_changed := expand_config_string(r.rewrite, 'routes', vars, env_map,
				false)!
			if rewrite_changed {
				r_copy.rewrite = rewrite
				changed = true
			}
			rewrite_strip_prefix, rewrite_strip_prefix_changed := expand_config_string(r.rewrite_strip_prefix,
				'routes', vars, env_map, false)!
			if rewrite_strip_prefix_changed {
				r_copy.rewrite_strip_prefix = rewrite_strip_prefix
				changed = true
			}
			location, location_changed := expand_config_string(r.location, 'routes', vars, env_map,
				false)!
			if location_changed {
				r_copy.location = location
				changed = true
			}
			body, body_changed := expand_config_string(r.body, 'routes', vars, env_map, false)!
			if body_changed {
				r_copy.body = body
				changed = true
			}
			next_routes << r_copy
		}
		cfg.routes = next_routes.clone()

		// 展开 executors
		mut next_executors := map[string]ExecutorSpecConfig{}
		for name, spec in cfg.executors {
			mut spec_copy := spec

			socket, socket_changed := expand_config_string(spec.worker.socket, 'executors.${name}',
				vars, env_map, false)!
			if socket_changed {
				spec_copy.worker.socket = socket
				changed = true
			}
			expanded_socket_prefix, socket_prefix_changed := expand_config_string(spec.worker.socket_prefix,
				'executors.${name}', vars, env_map, false)!
			if socket_prefix_changed {
				spec_copy.worker.socket_prefix = expanded_socket_prefix
				changed = true
			}
			cmd, cmd_changed := expand_config_string(spec.worker.cmd, 'executors.${name}', vars,
				env_map, false)!
			if cmd_changed {
				spec_copy.worker.cmd = cmd
				changed = true
			}

			bin, bin_changed := expand_config_string(spec.php.bin, 'executors.${name}', vars,
				env_map, false)!
			if bin_changed {
				spec_copy.php.bin = bin
				changed = true
			}
			worker_entry, worker_entry_changed := expand_config_string(spec.php.worker_entry,
				'executors.${name}', vars, env_map, false)!
			if worker_entry_changed {
				spec_copy.php.worker_entry = worker_entry
				changed = true
			}
			app_entry, app_entry_changed := expand_config_string(spec.php.app_entry,
				'executors.${name}', vars, env_map, false)!
			if app_entry_changed {
				spec_copy.php.app_entry = app_entry
				changed = true
			}

			next_executors[name] = spec_copy
		}
		cfg.executors = next_executors.clone()

		if !changed {
			cfg.server.index, _ = expand_config_string(cfg.server.index, 'server', vars, env_map,
				false)!
			if cfg.server.index != '' {
				cfg.worker.env['VHTTPD_INDEX'] = cfg.server.index
				for name, spec in cfg.executors {
					mut spec_copy := spec
					spec_copy.worker.env['VHTTPD_INDEX'] = cfg.server.index
					cfg.executors[name] = spec_copy
				}
			}
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

pub fn resolve_config_path(root string, raw string) string {
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
	cfg.site.document_root = resolve_config_path(cfg.paths.root, cfg.site.document_root)
	cfg.files.event_log = resolve_config_path(cfg.paths.root, cfg.files.event_log)
	cfg.files.pid_file = resolve_config_path(cfg.paths.root, cfg.files.pid_file)
	cfg.server.ssl.cert = resolve_config_path(cfg.paths.root, cfg.server.ssl.cert)
	cfg.server.ssl.cert_key = resolve_config_path(cfg.paths.root, cfg.server.ssl.cert_key)
	for name, mut listener in cfg.listeners {
		listener.ssl.cert = resolve_config_path(cfg.paths.root, listener.ssl.cert)
		listener.ssl.cert_key = resolve_config_path(cfg.paths.root, listener.ssl.cert_key)
		cfg.listeners[name] = listener
	}
	for name, mut site in cfg.sites {
		site.ssl.cert = resolve_config_path(cfg.paths.root, site.ssl.cert)
		site.ssl.cert_key = resolve_config_path(cfg.paths.root, site.ssl.cert_key)
		cfg.sites[name] = site
	}
	cfg.db.socket = resolve_config_path(cfg.paths.root, cfg.db.socket)
	cfg.cache.socket = resolve_config_path(cfg.paths.root, cfg.cache.socket)
	cfg.worker.socket = resolve_config_path(cfg.paths.root, cfg.worker.socket)
	cfg.worker.socket_prefix = resolve_config_path(cfg.paths.root, cfg.worker.socket_prefix)
	for i, raw in cfg.worker.sockets {
		cfg.worker.sockets[i] = resolve_config_path(cfg.paths.root, raw)
	}
	if app_entry := cfg.worker.env['VHTTPD_APP'] {
		cfg.worker.env['VHTTPD_APP'] = resolve_config_path(cfg.paths.root, app_entry)
	}
	if document_root := cfg.worker.env['DOCUMENT_ROOT'] {
		cfg.worker.env['DOCUMENT_ROOT'] = resolve_config_path(cfg.paths.root, document_root)
	}
	cfg.php.worker_entry = resolve_config_path(cfg.paths.root, cfg.php.worker_entry)
	cfg.php.app_entry = resolve_config_path(cfg.paths.root, cfg.php.app_entry)
	for i, raw in cfg.php.extensions {
		cfg.php.extensions[i] = resolve_config_path(cfg.paths.root, raw)
	}
	cfg.vjsx.app_entry = resolve_config_path(cfg.paths.root, cfg.vjsx.app_entry)
	cfg.vjsx.module_root = resolve_config_path(cfg.paths.root, cfg.vjsx.module_root)
	cfg.vjsx.build_root = resolve_config_path(cfg.paths.root, cfg.vjsx.build_root)
	cfg.vjsx.signature_root = resolve_config_path(cfg.paths.root, cfg.vjsx.signature_root)
	for name, mut plugin in cfg.plugins {
		plugin.entry = resolve_config_path(cfg.paths.root, plugin.entry)
		plugin.app_entry = resolve_config_path(cfg.paths.root, plugin.app_entry)
		plugin.module_root = resolve_config_path(cfg.paths.root, plugin.module_root)
		plugin.build_root = resolve_config_path(cfg.paths.root, plugin.build_root)
		plugin.signature_root = resolve_config_path(cfg.paths.root, plugin.signature_root)
		cfg.plugins[name] = plugin
	}
	cfg.assets.root = resolve_config_path(cfg.paths.root, cfg.assets.root)
	cfg.codex.cwd = resolve_config_path(cfg.paths.root, cfg.codex.cwd)

	// 解析 routes 路径
	for i in 0 .. cfg.routes.len {
		if cfg.routes[i].root != '' {
			cfg.routes[i].root = resolve_config_path(cfg.paths.root, cfg.routes[i].root)
		}
	}

	// 解析 executors 里的路径
	for name, mut spec in cfg.executors {
		spec.worker.socket = resolve_config_path(cfg.paths.root, spec.worker.socket)
		spec.worker.socket_prefix = resolve_config_path(cfg.paths.root, spec.worker.socket_prefix)
		for j, raw in spec.worker.sockets {
			spec.worker.sockets[j] = resolve_config_path(cfg.paths.root, raw)
		}
		if spec_app_entry := spec.worker.env['VHTTPD_APP'] {
			spec.worker.env['VHTTPD_APP'] = resolve_config_path(cfg.paths.root, spec_app_entry)
		}
		if spec_document_root := spec.worker.env['DOCUMENT_ROOT'] {
			spec.worker.env['DOCUMENT_ROOT'] = resolve_config_path(cfg.paths.root,
				spec_document_root)
		}
		spec.php.worker_entry = resolve_config_path(cfg.paths.root, spec.php.worker_entry)
		spec.php.app_entry = resolve_config_path(cfg.paths.root, spec.php.app_entry)
		for j, raw in spec.php.extensions {
			spec.php.extensions[j] = resolve_config_path(cfg.paths.root, raw)
		}
		spec.vjsx.app_entry = resolve_config_path(cfg.paths.root, spec.vjsx.app_entry)
		spec.vjsx.module_root = resolve_config_path(cfg.paths.root, spec.vjsx.module_root)
		spec.vjsx.build_root = resolve_config_path(cfg.paths.root, spec.vjsx.build_root)
		spec.vjsx.signature_root = resolve_config_path(cfg.paths.root, spec.vjsx.signature_root)
		cfg.executors[name] = spec
	}
}

pub fn build_config_variable_map(cfg VhttpdConfig) map[string]string {
	mut vars := {
		'server.host':                    cfg.server.host
		'server.port':                    '${cfg.server.port}'
		'server.ssl.cert':                cfg.server.ssl.cert
		'server.ssl.cert_key':            cfg.server.ssl.cert_key
		'files.event_log':                cfg.files.event_log
		'files.pid_file':                 cfg.files.pid_file
		'db.socket':                      cfg.db.socket
		'db.driver':                      cfg.db.driver
		'db.pool_name':                   cfg.db.pool_name
		'db.mysql.host':                  cfg.db.mysql.host
		'db.mysql.port':                  '${cfg.db.mysql.port}'
		'db.mysql.username':              cfg.db.mysql.username
		'db.mysql.database':              cfg.db.mysql.database
		'db.mysql.pool_size':             '${cfg.db.mysql.pool_size}'
		'db.mysql.idle_ping_ms':          '${cfg.db.mysql.idle_ping_ms}'
		'db.mysql.init_sql':              cfg.db.mysql.init_sql.join('; ')
		'db.pgsql.host':                  cfg.db.pgsql.host
		'db.pgsql.port':                  '${cfg.db.pgsql.port}'
		'db.pgsql.username':              cfg.db.pgsql.username
		'db.pgsql.database':              cfg.db.pgsql.database
		'db.pgsql.pool_size':             '${cfg.db.pgsql.pool_size}'
		'cache.socket':                   cfg.cache.socket
		'paths.root':                     cfg.paths.root
		'site.root':                      cfg.site.document_root
		'site.index':                     cfg.site.index
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
		'vjsx.build_root':                cfg.vjsx.build_root
		'vjsx.signature_root':            cfg.vjsx.signature_root
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
		'feishu.bridge.enabled':          '${cfg.feishu.bridge.enabled}'
		'feishu.bridge.ws_url':           cfg.feishu.bridge.ws_url
		'feishu.bridge.client_id':        cfg.feishu.bridge.client_id
		'feishu.bridge.token':            cfg.feishu.bridge.token
		'feishu.bridge.target_id':        cfg.feishu.bridge.target_id
		'openai.enabled':                 '${cfg.openai.enabled}'
		'openai.base_path':               cfg.openai.base_path
		'openai.default_backend':         cfg.openai.default_backend
		'openai.plugin':                  cfg.openai.plugin
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
	for name, backend in cfg.openai.backends {
		vars['openai.backends.${name}.kind'] = backend.kind
		vars['openai.backends.${name}.base_url'] = backend.base_url
		vars['openai.backends.${name}.api_key_env'] = backend.api_key_env
	}
	for name, route in cfg.openai.routes {
		vars['openai.routes.${name}.model'] = route.model
		vars['openai.routes.${name}.backend'] = route.backend
		vars['openai.routes.${name}.upstream_model'] = route.upstream_model
	}
	for name, plugin in cfg.plugins {
		vars['plugins.${name}.kind'] = plugin.kind
		vars['plugins.${name}.entry'] = plugin.entry
		vars['plugins.${name}.app_entry'] = plugin.app_entry
		vars['plugins.${name}.module_root'] = plugin.module_root
		vars['plugins.${name}.build_root'] = plugin.build_root
		vars['plugins.${name}.signature_root'] = plugin.signature_root
		vars['plugins.${name}.runtime_profile'] = plugin.runtime_profile
	}
	return vars
}

pub fn expand_config_string(raw string, scope string, vars map[string]string, env map[string]string, changed bool) !(string, bool) {
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
		replacement := resolve_config_variable(expr, scope, vars, env)!
		next := out[..start] + replacement + out[end + 1..]
		if next == out {
			break
		}
		out = next
		any_change = true
	}
	return out, any_change
}

fn config_variable_scope(key string, fallback_scope string) string {
	if key.contains('.') {
		parts := key.split('.')
		if parts.len > 1 {
			return parts[..parts.len - 1].join('.')
		}
	}
	return fallback_scope
}

fn resolve_config_variable(expr string, scope string, vars map[string]string, env map[string]string) !string {
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
	if !key.contains('.') && scope.trim_space() != '' {
		scoped_key := '${scope}.${key}'
		if scoped_key in vars {
			mut value := vars[scoped_key]
			if value.contains('\${') {
				value, _ = expand_config_string(value, scope, vars, env, false)!
			}
			return value
		}
	}
	if key in vars {
		mut value := vars[key]
		if value.contains('\${') {
			value_scope := config_variable_scope(key, scope)
			value, _ = expand_config_string(value, value_scope, vars, env, false)!
		}
		return value
	}
	if has_default {
		return default_raw
	}
	return error('unknown config variable "${key}"')
}

// resolve_worker_sockets_with_defaults resolves the worker socket list from CLI args.
// Returns explicit list if --worker-sockets is provided, otherwise expands --worker-socket
// with --worker-pool-size using --worker-socket-prefix.
pub fn resolve_worker_sockets_with_defaults(args []string, default_worker_socket string, default_pool_size int, default_socket_prefix string, default_worker_sockets string) []string {
	worker_sockets_arg := CliArgs.string_or(args, '--worker-sockets', default_worker_sockets)
	if worker_sockets_arg != '' {
		mut sockets := []string{}
		for raw in worker_sockets_arg.split(',') {
			s := raw.trim_space()
			if s != '' {
				sockets << s
			}
		}
		return sockets
	}
	worker_socket := CliArgs.string_or(args, '--worker-socket', default_worker_socket)
	pool_size := CliArgs.int_or(args, '--worker-pool-size', default_pool_size)
	if pool_size <= 1 {
		return if worker_socket == '' { []string{} } else { [worker_socket] }
	}
	mut prefix := CliArgs.string_or(args, '--worker-socket-prefix', default_socket_prefix)
	if prefix == '' {
		prefix = socket_prefix(worker_socket)
	}
	mut sockets := []string{cap: pool_size}
	for i in 0 .. pool_size {
		sockets << '${prefix}_${i}.sock'
	}
	return sockets
}

// socket_prefix strips the .sock extension from a worker socket path.
pub fn socket_prefix(worker_socket string) string {
	if worker_socket.len >= 5 && worker_socket.ends_with('.sock') {
		return worker_socket[..worker_socket.len - 5]
	}
	if worker_socket != '' {
		return worker_socket
	}
	return '/tmp/vslim_worker'
}
