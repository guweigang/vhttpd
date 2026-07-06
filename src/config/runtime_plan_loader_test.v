module config

import json
import os

fn test_load_runtime_plan_file_uses_strict_v2_when_version_is_two() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_v2_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080

[engines.vjsx]
kind = "vjsx"
entry = "app.mts"

[adapters.app]
kind = "http-handler"
engine = "engine:vjsx"

[[pipelines]]
id = "site"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert !plan.source.compatibility
	assert plan.source.config_path == os.abs_path(config_file)
	assert plan.listeners['web'].port == 18080
	assert plan.pipeline('site')?.egress.str() == 'adapter:app'
}

fn test_load_runtime_plan_file_falls_back_to_v1_without_version() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_v1_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[server]
host = "127.0.0.1"
port = 18081

[site]
name = "legacy"
document_root = "/srv/legacy"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert plan.source.compatibility
	assert plan.listeners['default'].port == 18081
	assert plan.adapters['legacy/default'].options.strings['document_root'] == '/srv/legacy'
	assert plan.diagnostics.any(it.code == 'legacy_schema')
}

fn test_load_vhttpd_config_accepts_provider_runtime_driver_map() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_runtime_config_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[paths]
root = "${temp_dir}"
provider_plugin = "plugins/feishu-runtime.mts"

[plugins.feishu_runtime]
kind = "vjsx"
app_entry = "\${paths.provider_plugin}"
runtime_profile = "node"

[providers.feishu.runtime]
driver = "typescript"
plugin = "feishu_runtime"

[providers.feishu.capabilities]
send_message = "feishu.message.send"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	cfg := load_vhttpd_config([config_file]) or { panic(err) }
	assert cfg.providers['feishu'].runtime.driver == 'typescript'
	assert cfg.providers['feishu'].runtime.plugin == 'feishu_runtime'
	assert cfg.providers['feishu'].capabilities['send_message'] == 'feishu.message.send'
	assert cfg.plugins['feishu_runtime'].app_entry.ends_with('/plugins/feishu-runtime.mts')
}

fn test_load_runtime_plan_file_projects_v2_provider_runtime_driver_map() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_provider_runtime_plan_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18082

[engines.vjsx]
kind = "vjsx"
entry = "app.mts"

[adapters.app]
kind = "http-handler"
engine = "engine:vjsx"

[providers.feishu.runtime]
driver = "typescript"
plugin = "feishu_runtime"
engine = "engine:vjsx"

[providers.feishu.capabilities]
send_message = "feishu.message.send"
upload_image = "feishu.image.upload"

[[pipelines]]
id = "site"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.providers['feishu'].driver == 'typescript'
	assert plan.providers['feishu'].plugin == 'feishu_runtime'
	assert plan.providers['feishu'].engine?.str() == 'engine:vjsx'
	assert plan.providers['feishu'].capabilities['send_message'] == 'feishu.message.send'
	assert plan.providers['feishu'].capabilities['upload_image'] == 'feishu.image.upload'
	encoded := json.encode(plan)
	assert encoded.contains('"providers":{"feishu"')
	assert encoded.contains('"plugin":"feishu_runtime"')
}

fn test_provider_ids_from_v2_text_detects_nested_provider_tables() {
	ids := provider_ids_from_v2_text('
[providers.feishu.runtime]
driver = "vjsx"

[providers.custom.capabilities]
send = "custom.send"
')

	assert ids['feishu']
	assert ids['custom']
}

fn test_load_runtime_plan_file_rejects_unsupported_version() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_bad_version_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, 'version = 99') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	if _ := load_runtime_plan_file(config_file) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_unsupported_version:99'
	}
}

fn test_load_runtime_plan_file_rejects_unknown_v2_root_field() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_unknown_root_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2
surprise = true
') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	if _ := load_runtime_plan_file(config_file) {
		assert false
	} else {
		assert err.msg() == 'v2_config_unknown_field:surprise'
	}
}

fn test_load_runtime_plan_file_rejects_unknown_v2_nested_field() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_unknown_nested_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[engines.app]
kind = "vjsx"
entry = "app.mts"
poolz = 3
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	if _ := load_runtime_plan_file(config_file) {
		assert false
	} else {
		assert err.msg() == 'v2_config_unknown_field:engines.app.poolz'
	}
}

fn test_load_runtime_plan_file_allows_extension_options() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_options_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18082

[engines.app]
kind = "vjsx"
entry = "app.mts"
options = { custom_flag = "ok" }

[adapters.app]
kind = "http-handler"
engine = "engine:app"
options = { custom_adapter_flag = "ok" }

[transforms.rewrite]
kind = "vjsx"
engine = "engine:app"
handler = "rewrite.handle"
options = { custom_transform_flag = "ok" }

[transforms.rewrite.bool_options]
stateful = true

[[pipelines]]
id = "site"
ingress = "listener:web"
match.paths = ["*"]
match.headers = { x_custom = "yes" }
transforms = ["transform:rewrite"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.engines['app'].options.strings['custom_flag'] == 'ok'
	assert plan.adapters['app'].options.strings['custom_adapter_flag'] == 'ok'
	assert plan.transforms['rewrite'].options.strings['custom_transform_flag'] == 'ok'
	assert plan.transforms['rewrite'].options.bools['stateful']
	assert plan.pipelines[0].match.headers['x_custom'] == 'yes'
}

fn test_load_runtime_plan_file_allows_record_options() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_record_options_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18082

[engines.app]
kind = "vjsx"
entry = "app.mts"

[adapters.app]
kind = "http-handler"
engine = "engine:app"

[adapters.openai]
kind = "openai"
options = { default_backend = "main" }
record_options = { backends = [{ id = "main", kind = "openai_http", base_url = "https://api.example.test/v1" }] }

[transforms.rewrite]
kind = "vjsx"
engine = "engine:app"
handler = "rewrite.handle"
record_options = { rules = [{ from = "/old", to = "/new" }] }

[[pipelines]]
id = "site"
ingress = "listener:web"
transforms = ["transform:rewrite"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.transforms['rewrite'].options.record_lists['rules'].len == 1
	assert plan.transforms['rewrite'].options.record_lists['rules'][0]['from'] == '/old'
	assert plan.transforms['rewrite'].options.record_lists['rules'][0]['to'] == '/new'
	assert plan.adapters['openai'].options.record_lists['backends'].len == 1
	assert plan.adapters['openai'].options.record_lists['backends'][0]['id'] == 'main'
	assert plan.adapters['openai'].options.record_lists['backends'][0]['base_url'] == 'https://api.example.test/v1'
}

fn test_load_runtime_plan_file_accepts_hello_v2_example() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..', '..'))
	config_file := os.join_path(repo_root, 'examples', 'config', 'hello-v2.toml')
	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert !plan.source.compatibility
	assert plan.listeners['web'].port == 19882
	assert plan.engines['hello'].kind == 'vjsx'
	assert plan.adapters['hello'].engine?.str() == 'engine:hello'
	assert plan.pipelines[0].id == 'hello'
}

fn test_repository_v2_examples_are_strict_v2_style() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..', '..'))
	examples := [
		os.join_path(repo_root, 'examples', 'config', 'hello-v2.toml'),
		os.join_path(repo_root, 'examples', 'config', 'provider-websocket-feishu.toml'),
		os.join_path(repo_root, 'examples', 'config', 'relay-hub-v2.toml'),
		os.join_path(repo_root, 'examples', 'config', 'relay-public-v2.toml'),
		os.join_path(repo_root, 'examples', 'config', 'relay-agent-v2.toml'),
		os.join_path(repo_root, 'examples', 'config', 'relay-agent-local-v2.toml'),
		os.join_path(repo_root, 'examples', 'wordpress', 'vhttpd-v2.toml'),
	]
	legacy_sections := ['[files]', '[worker]', '[executor]', '[php]', '[vjsx]', '[admin]',
		'[[routes]]']
	for config_file in examples {
		text := os.read_file(config_file) or { panic(err) }
		assert text.contains('version = 2')
		normalized := '\n${text}'
		for section in legacy_sections {
			assert !normalized.contains('\n${section}')
		}
		plan := load_runtime_plan_file(config_file) or { panic(err) }
		assert !plan.source.compatibility
	}
}

fn test_load_runtime_plan_file_accepts_provider_websocket_feishu_example() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..', '..'))
	config_file := os.join_path(repo_root, 'examples', 'config', 'provider-websocket-feishu.toml')
	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert !plan.source.compatibility
	assert plan.providers['feishu'].driver == 'native'
	assert plan.providers['feishu'].protocol == 'websocket'
	assert plan.providers['feishu'].plugin == 'feishu-provider-hooks'
	assert plan.providers['feishu'].engine?.str() == 'engine:provider_events'
	assert plan.providers['feishu'].options.string_maps['hooks']['handshake'] == 'handshake'
	assert plan.providers['feishu'].options.string_maps['hooks']['normalize'] == 'normalize'
	assert plan.adapters['feishu_events'].kind == 'feishu-events'
	assert plan.adapters['feishu_events'].options.record_lists['apps'].len == 1
	assert plan.pipeline('provider.feishu.events')?.ingress.str() == 'provider:feishu'
	assert plan.pipeline('provider.feishu.events')?.transforms[0].str() == 'transform:feishu_event'
}

fn test_load_runtime_plan_file_accepts_wordpress_v2_example() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..', '..'))
	config_file := os.join_path(repo_root, 'examples', 'wordpress', 'vhttpd-v2.toml')
	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.source.schema_version == 2
	assert !plan.source.compatibility
	assert plan.listeners['web'].tls.enabled
	assert plan.resources['db/wordpress'].options.strings['pool_name'] == 'wordpress'
	assert plan.resources['cache/wordpress'].kind == 'session-store'
	assert plan.resources['storage/wordpress'].options.strings['root'] == '/Users/guweigang/wwwroot/wordpress'
	assert plan.engines['php'].kind == 'php-worker'
	assert plan.engines['php'].resources.map(it.str()).contains('resource:db/wordpress')
	assert plan.engines['php-cgi'].kind == 'php-cgi'
	assert plan.adapters['wordpress-worker'].engine?.str() == 'engine:php'
	assert plan.adapters['wordpress-cgi'].engine?.str() == 'engine:php-cgi'
	assert plan.adapters['forbidden'].options.strings['status'] == '403'
	assert plan.adapters['vhttpd-upload'].options.strings['completed_pipeline'] == 'pipeline:upload.completed'
	assert plan.policies['cache/front-page'].options.ints['ttl_ms'] == 30000
	assert plan.policies['response/wp-json-options'].options.string_maps['headers']['Access-Control-Allow-Methods'] == 'GET, HEAD, OPTIONS'
	assert plan.transforms['wp-json-rewrite'].options.strings['strip_prefix'] == '/wp-json'
	assert plan.pipeline('security.deny-core-files')?.egress.str() == 'adapter:forbidden'
	assert plan.pipeline('wordpress.compat-entrypoints')?.egress.str() == 'adapter:wordpress-cgi'
	assert plan.pipeline('wordpress.front-page')?.egress.str() == 'adapter:wordpress-worker'
	assert plan.pipeline('rest.pretty-route')?.transforms[0].str() == 'transform:wp-json-rewrite'
	assert plan.pipeline('upload.completed')?.transforms[0].str() == 'transform:upload-completed'
}

fn test_load_runtime_plan_file_normalizes_v2_event_adapter_kind() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_event_adapter_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
host = "127.0.0.1"
port = 18080

[adapters.event]
kind = "event"
topic = "inventory.changed"

[adapters.health]
kind = "fixed-response"
options.status = "200"
options.body = "ok"

[[pipelines]]
id = "health"
ingress = "listener:web"
match.paths = ["/health"]
egress = "adapter:health"

[[pipelines]]
id = "inventory.changed"
ingress = "adapter:event"
match.metadata = { event = "inventory.changed" }
egress = "adapter:event"
') or {
		panic(err)
	}
	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.adapters['event'].kind == 'event-ingress'
}

fn test_load_runtime_plan_file_accepts_v2_provider_action_adapter() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_provider_action_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
host = "127.0.0.1"
port = 18080

[adapters.provider_send]
kind = "provider-action"
provider = "feishu"
action = "send_message"
runtime_driver = "vjsx"
runtime_plugin = "feishu_runtime"
runtime_engine = "engine:provider_runtime"
capability = "feishu.message.send"

[engines.provider_runtime]
kind = "vjsx"
entry = "provider-runtime.mts"

[[pipelines]]
id = "provider.send"
ingress = "listener:web"
match.methods = ["POST"]
match.paths = ["/provider/send"]
egress = "adapter:provider_send"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.adapters['provider_send'].kind == 'provider-action'
	assert plan.adapters['provider_send'].options.strings['provider'] == 'feishu'
	assert plan.adapters['provider_send'].options.strings['action'] == 'send_message'
	assert plan.providers['feishu'].driver == 'vjsx'
	assert plan.providers['feishu'].plugin == 'feishu_runtime'
	assert plan.providers['feishu'].engine?.str() == 'engine:provider_runtime'
	assert plan.providers['feishu'].capabilities['send_message'] == 'feishu.message.send'
}

fn test_load_runtime_plan_file_rejects_v2_provider_action_without_provider() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_provider_action_bad_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[listeners.web]
protocol = "http"
host = "127.0.0.1"
port = 18080

[adapters.provider_send]
kind = "provider-action"
action = "send_message"

[[pipelines]]
id = "provider.send"
ingress = "listener:web"
match.methods = ["POST"]
match.paths = ["/provider/send"]
egress = "adapter:provider_send"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	if _ := load_runtime_plan_file(config_file) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_adapter_missing_provider:provider_send'
	}
}

fn test_load_runtime_plan_file_resolves_v2_relative_paths_and_env_defaults() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_runtime_plan_loader_v2_paths_test')
	config_dir := os.join_path(temp_dir, 'config')
	os.mkdir_all(config_dir) or { panic(err) }
	app_file := os.join_path(config_dir, 'app.mts')
	os.write_file(app_file,
		'export default { async handle() { return { status: 200, body: "ok" }; } };') or {
		panic(err)
	}
	config_file := os.join_path(config_dir, 'vhttpd.toml')
	os.write_file(config_file, '
version = 2

[server]
pid_file = "run/vhttpd.pid"

[observability]
event_log = "\${paths.root}/logs/events.ndjson"

[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18083

[resources.storage.uploads]
kind = "filesystem"
root = "uploads"

[engines.app]
kind = "vjsx"
entry = "\${env.VHTTPD_TEST_V2_ENTRY:-app.mts}"
module_root = "."

[adapters.app]
kind = "http-handler"
engine = "engine:app"
document_root = "public"

[[pipelines]]
id = "site"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:app"
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}

	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.server.pid_file == os.join_path(config_dir, 'run', 'vhttpd.pid')
	assert plan.observability.event_log == os.join_path(config_dir, 'logs', 'events.ndjson')
	assert plan.resources['storage/uploads'].options.strings['root'] == os.join_path(config_dir,
		'uploads')
	assert plan.engines['app'].options.strings['entry'] == app_file
	assert plan.engines['app'].options.strings['module_root'] == config_dir
	assert plan.adapters['app'].options.strings['document_root'] == os.join_path(config_dir,
		'public')
}

fn test_load_runtime_plan_file_compiles_wordpress_paseo_admin_stack_example() {
	config_file := os.join_path(os.dir(@FILE), '..', '..', 'examples', 'wordpress',
		'wordpress-paseo-admin-v2.toml')
	plan := load_runtime_plan_file(config_file) or { panic(err) }
	assert plan.control.listener?.str() == 'listener:control'
	assert plan.control.token == 'Abcd.1234'
	assert plan.listeners['web'].port == 8080
	assert plan.listeners['admin_ui'].port == 20210
	assert plan.listeners['control'].port == 20211
	assert plan.listeners['paseo'].port == 19901
	assert plan.engines['php'].kind == 'php-worker'
	assert plan.engines['admin-ui'].kind == 'vjsx'
	assert plan.engines['paseo'].kind == 'vjsx'
	assert plan.engines['paseo'].options.bools['websocket_dispatch'] == true
	assert plan.adapters['admin-ui'].engine?.str() == 'engine:admin-ui'
	assert plan.adapters['paseo'].engine?.str() == 'engine:paseo'
	assert plan.pipelines.any(it.id == 'admin.ui' && it.ingress.str() == 'listener:admin_ui'
		&& it.egress.str() == 'adapter:admin-ui')
	assert plan.pipelines.any(it.id == 'paseo.relay' && it.ingress.str() == 'listener:paseo'
		&& it.egress.str() == 'adapter:paseo')
	assert plan.pipelines.any(it.id == 'wordpress.front-page')
	assert plan.pipelines.any(it.id == 'security.deny-protected-php'
		&& it.match.path_regexps.len == 3)
	assert !plan.pipelines.any(it.id == 'security.deny-upload-php')
	assert !plan.pipelines.any(it.id == 'security.deny-includes-php')
	assert !plan.pipelines.any(it.id == 'security.deny-admin-includes-php')
	assert plan.pipelines.any(it.id == 'woocommerce.account-page-by-id'
		&& it.match.query['page_id'] == ['9', '10', '11'])
	assert !plan.pipelines.any(it.id == 'woocommerce.cart-page')
	assert !plan.pipelines.any(it.id == 'woocommerce.checkout-page')
	assert !plan.pipelines.any(it.id == 'woocommerce.account-page')
}
