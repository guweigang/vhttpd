module config

pub struct V2Config {
pub mut:
	version       int = 2
	server        V2ServerSpec
	listeners     map[string]V2ListenerSpec
	control       V2ControlSpec
	observability V2ObservabilitySpec
	resources     V2ResourceSpecs
	engines       map[string]V2EngineSpec
	adapters      map[string]V2AdapterSpec
	transforms    map[string]V2TransformSpec
	policies      V2PolicySpecs
	pipelines     []V2PipelineSpec
	relays        map[string]V2RelaySpec
}

pub struct V2ServerSpec {
pub mut:
	timezone            string = 'Asia/Shanghai'
	pid_file            string @[toml: 'pid_file']
	shutdown_timeout_ms int    @[toml: 'shutdown_timeout_ms']
}

pub struct V2ListenerSpec {
pub mut:
	protocol  string
	transport string
	host      string
	port      int
	tls       V2TlsSpec
}

pub struct V2TlsSpec {
pub mut:
	enabled      bool
	cert         string
	cert_key     string @[toml: 'cert_key']
	certificates []V2TlsCertificateSpec
}

pub struct V2TlsCertificateSpec {
pub mut:
	hosts    []string
	cert     string
	cert_key string @[toml: 'cert_key']
}

pub struct V2ControlSpec {
pub mut:
	listener        string
	token           string
	internal_socket string @[toml: 'internal_socket']
}

pub struct V2ObservabilitySpec {
pub mut:
	event_log string @[toml: 'event_log']
	log_level string = 'info' @[toml: 'log_level']
	tracing   V2TracingSpec
}

pub struct V2TracingSpec {
pub mut:
	enabled     bool
	exporter    string
	endpoint    string
	sample_rate f64 @[toml: 'sample_rate']
}

pub struct V2ResourceSpecs {
pub mut:
	db      map[string]V2DbResourceSpec
	cache   map[string]V2CacheResourceSpec
	storage map[string]V2StorageResourceSpec
	secret  map[string]V2SecretResourceSpec
}

pub struct V2DbResourceSpec {
pub mut:
	kind         string
	host         string
	port         int
	database     string
	username     string
	password     string
	pool_size    int      @[toml: 'pool_size']
	idle_ping_ms int      @[toml: 'idle_ping_ms']
	init_sql     []string @[toml: 'init_sql']
	options      map[string]string
}

pub struct V2CacheResourceSpec {
pub mut:
	kind      string
	socket    string
	url       string
	namespace string
	options   map[string]string
}

pub struct V2StorageResourceSpec {
pub mut:
	kind    string
	root    string
	bucket  string
	options map[string]string
}

pub struct V2SecretResourceSpec {
pub mut:
	kind    string
	source  string
	options map[string]string
}

pub struct V2EngineSpec {
pub mut:
	kind                   string
	entry                  string
	app                    string
	binary                 string
	module_root            string @[toml: 'module_root']
	build_root             string @[toml: 'build_root']
	runtime_profile        string @[toml: 'runtime_profile']
	pool_size              int    @[toml: 'pool_size']
	thread_count           int    @[toml: 'thread_count']
	queue_capacity         int    @[toml: 'queue_capacity']
	queue_timeout_ms       int    @[toml: 'queue_timeout_ms']
	read_timeout_ms        int    @[toml: 'read_timeout_ms']
	restart_backoff_ms     int    @[toml: 'restart_backoff_ms']
	restart_backoff_max_ms int    @[toml: 'restart_backoff_max_ms']
	max_requests           int    @[toml: 'max_requests']
	autostart              bool
	stream_dispatch        bool @[toml: 'stream_dispatch']
	websocket_dispatch     bool @[toml: 'websocket_dispatch']
	enable_fs              bool @[toml: 'enable_fs']
	enable_process         bool @[toml: 'enable_process']
	enable_network         bool @[toml: 'enable_network']
	socket                 string
	socket_prefix          string @[toml: 'socket_prefix']
	sockets                []string
	signature_root         string   @[toml: 'signature_root']
	signature_include      []string @[toml: 'signature_include']
	signature_exclude      []string @[toml: 'signature_exclude']
	resources              []string
	capabilities           []string
	env                    map[string]string
	args                   []string
	extensions             []string
	options                map[string]string
}

pub struct V2AdapterSpec {
pub mut:
	kind               string
	engine             string
	storage            string
	document_root      string @[toml: 'document_root']
	index              string
	root               string
	base_url           string @[toml: 'base_url']
	timeout_ms         int    @[toml: 'timeout_ms']
	max_body_bytes     int    @[toml: 'max_body_bytes']
	completed_pipeline string @[toml: 'completed_pipeline']
	topic              string
	options            map[string]string
	int_options        map[string]int                 @[toml: 'int_options']
	bool_options       map[string]bool                @[toml: 'bool_options']
	list_options       map[string][]string            @[toml: 'list_options']
	map_options        map[string]map[string]string   @[toml: 'map_options']
	record_options     map[string][]map[string]string @[toml: 'record_options']
}

pub struct V2TransformSpec {
pub mut:
	kind         string
	engine       string
	handler      string
	target       string
	strip_prefix string @[toml: 'strip_prefix']
	options      map[string]string
}

pub struct V2PolicySpecs {
pub mut:
	cache       map[string]V2CachePolicySpec
	limits      map[string]V2LimitPolicySpec
	security    map[string]V2SecurityPolicySpec
	response    map[string]V2ResponsePolicySpec
	retry       map[string]V2RetryPolicySpec
	concurrency map[string]V2ConcurrencyPolicySpec
}

pub struct V2CachePolicySpec {
pub mut:
	cache_control          string   @[toml: 'cache_control']
	ttl_ms                 int      @[toml: 'ttl_ms']
	bypass_cookie_patterns []string @[toml: 'bypass_cookie_patterns']
	ignore_cookie_patterns []string @[toml: 'ignore_cookie_patterns']
}

pub struct V2LimitPolicySpec {
pub mut:
	max_body_bytes int @[toml: 'max_body_bytes']
	timeout_ms     int @[toml: 'timeout_ms']
	queue_capacity int @[toml: 'queue_capacity']
}

pub struct V2SecurityPolicySpec {
pub mut:
	required_headers      map[string]string @[toml: 'required_headers']
	denied_query_patterns map[string]string @[toml: 'denied_query_patterns']
	allowed_origins       []string          @[toml: 'allowed_origins']
}

pub struct V2ResponsePolicySpec {
pub mut:
	headers map[string]string
}

pub struct V2RetryPolicySpec {
pub mut:
	max_attempts   int @[toml: 'max_attempts']
	backoff_ms     int @[toml: 'backoff_ms']
	max_backoff_ms int @[toml: 'max_backoff_ms']
}

pub struct V2ConcurrencyPolicySpec {
pub mut:
	max_in_flight     int    @[toml: 'max_in_flight']
	queue_capacity    int    @[toml: 'queue_capacity']
	queue_timeout_ms  int    @[toml: 'queue_timeout_ms']
	max_queue_per_key int    @[toml: 'max_queue_per_key']
	affinity_enabled  bool   @[toml: 'affinity_enabled']
	actor_enabled     bool   @[toml: 'actor_enabled']
	actor_fallback    string @[toml: 'actor_fallback']
	affinity_source   string @[toml: 'affinity_source']
	affinity_key      string @[toml: 'affinity_key']
	affinity_scope    string @[toml: 'affinity_scope']
	affinity_fallback string @[toml: 'affinity_fallback']
	events            []string
	options           map[string]string
	record_options    map[string][]map[string]string @[toml: 'record_options']
}

pub struct V2PipelineSpec {
pub mut:
	id         string
	group      string
	ingress    string
	match      V2MatchSpec
	transforms []string
	policies   []string
	egress     string
}

pub struct V2MatchSpec {
pub mut:
	methods     []string
	hosts       []string
	paths       []string
	path_regexp string @[toml: 'path_regexp']
	query       map[string]string
	headers     map[string]string
	metadata    map[string]string
}

pub struct V2RelaySpec {
pub mut:
	mode               string
	carrier            string
	listener           string
	url                string
	path               string
	auth               string
	node_id            string @[toml: 'node_id']
	token              string
	max_channels       int @[toml: 'max_channels']
	channel_buffer     int @[toml: 'channel_buffer']
	reconnect_delay_ms int @[toml: 'reconnect_delay_ms']
	options            map[string]string
}
