module config

import toml

fn test_v2_root_spec_decodes_every_stable_domain() {
	text := '
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "tmp/vhttpd.pid"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 8443

[control]
listener = "listener:web"

[observability]
event_log = "tmp/events.ndjson"

[resources.db.app]
kind = "mysql"
database = "app"
pool_size = 4

[resources.cache.app]
kind = "memory"
socket = "tmp/cache.sock"

[resources.storage.uploads]
kind = "filesystem"
root = "tmp/uploads"

[resources.secret.api]
kind = "env"
source = "API_KEY"

[engines.php]
kind = "php-worker"
entry = "vendor/bin/vphp-worker"
resources = ["resource:db/app", "resource:cache/app"]

[adapters.app]
kind = "http-handler"
engine = "engine:php"

[transforms.rewrite]
kind = "native"
handler = "http.rewrite"

[policies.cache.assets]
cache_control = "public, max-age=3600"

[policies.limits.upload]
max_body_bytes = 1024

[policies.security.api]
allowed_origins = ["https://example.com"]

[policies.response.secure]
headers = { x_frame_options = "DENY" }

[policies.retry.upstream]
max_attempts = 3

[policies.concurrency.app]
max_in_flight = 8

[[pipelines]]
id = "app"
ingress = "listener:web"
match.paths = ["*"]
transforms = ["transform:rewrite"]
policies = ["policy:limits/upload"]
egress = "adapter:app"

[relays.edge]
mode = "agent"
carrier = "websocket"
url = "wss://relay.example.com"
autostart = true
'
	cfg := toml.decode[V2Config](text) or { panic(err) }
	assert cfg.version == 2
	assert cfg.listeners['web'].port == 8443
	assert cfg.control.listener == 'listener:web'
	assert cfg.observability.event_log == 'tmp/events.ndjson'
	assert cfg.resources.db['app'].pool_size == 4
	assert cfg.resources.cache['app'].kind == 'memory'
	assert cfg.resources.storage['uploads'].root == 'tmp/uploads'
	assert cfg.resources.secret['api'].source == 'API_KEY'
	assert cfg.engines['php'].resources.len == 2
	assert cfg.adapters['app'].engine == 'engine:php'
	assert cfg.transforms['rewrite'].handler == 'http.rewrite'
	assert cfg.policies.cache['assets'].cache_control == 'public, max-age=3600'
	assert cfg.policies.limits['upload'].max_body_bytes == 1024
	assert cfg.policies.security['api'].allowed_origins == ['https://example.com']
	assert cfg.policies.response['secure'].headers['x_frame_options'] == 'DENY'
	assert cfg.policies.retry['upstream'].max_attempts == 3
	assert cfg.policies.concurrency['app'].max_in_flight == 8
	assert cfg.pipelines[0].match.paths == ['*']
	assert cfg.relays['edge'].carrier == 'websocket'
	assert cfg.relays['edge'].autostart
}
