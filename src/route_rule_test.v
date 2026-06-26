module main

import regex
import os
import config
import dispatch
import json
import net.http
import upstream.transport

fn test_route_rule_path_matching() {
	// 1. Precise match
	rule1 := RuntimeRouteRule{
		match_path: ['/index.html']
	}
	assert rule1.matches('/index.html') == true
	assert rule1.matches('/index.html/') == false
	assert rule1.matches('/index.htm') == false

	// 2. Wildcard prefix
	rule2 := RuntimeRouteRule{
		match_path: ['/api/*']
	}
	assert rule2.matches('/api/users') == true
	assert rule2.matches('/api/v1/status') == true
	assert rule2.matches('/api/') == true
	assert rule2.matches('/ap') == false

	// 3. Suffix match
	rule3 := RuntimeRouteRule{
		match_path: ['*.php']
	}
	assert rule3.matches('/index.php') == true
	assert rule3.matches('/api/index.php') == true
	assert rule3.matches('/index.phps') == false
	assert rule3.matches('/index.php/extra') == false

	// 4. Wildcard * (match all)
	rule4 := RuntimeRouteRule{
		match_path: ['*']
	}
	assert rule4.matches('/') == true
	assert rule4.matches('/any/path') == true
}

fn test_route_rule_regex_matching() {
	// Regular expression matching
	mut re1 := regex.regex_opt('^/users/([0-9]+)/profile$') or {
		assert false
		return
	}
	rule1 := RuntimeRouteRule{
		match_path_regexp: '^/users/([0-9]+)/profile$'
		re:                re1
	}
	assert rule1.matches('/users/123/profile') == true
	assert rule1.matches('/users/abc/profile') == false
	assert rule1.matches('/users/123/profile/extra') == false

	mut re2 := regex.regex_opt('\\.png$') or {
		assert false
		return
	}
	rule2 := RuntimeRouteRule{
		match_path_regexp: '\\.png$'
		re:                re2
	}
	assert rule2.matches('/images/logo.png') == true
	assert rule2.matches('/avatar.png') == true
	assert rule2.matches('/style.css') == false
}

fn test_route_rule_query_matching() {
	rule := RuntimeRouteRule{
		match_path:  ['/index.php']
		match_query: {
			'rest_route': '*'
		}
	}
	assert rule.matches_request('/index.php', {
		'rest_route': '/wp/v2/users/me'
	}) == true
	assert rule.matches_request('/index.php', map[string]string{}) == false
	assert rule.matches_request('/', {
		'rest_route': '/wp/v2/users/me'
	}) == false
}

fn test_route_rule_method_matching() {
	rule := RuntimeRouteRule{
		match_method: ['POST']
		match_path:   ['/xmlrpc.php']
	}
	assert rule.matches_http_request('POST', '/xmlrpc.php', map[string]string{})
	assert !rule.matches_http_request('GET', '/xmlrpc.php', map[string]string{})
	assert !rule.matches_http_request('POST', '/index.php', map[string]string{})
}

fn test_route_rule_method_matching_supports_preflight_split() {
	preflight := RuntimeRouteRule{
		match_method: ['OPTIONS']
		match_path:   ['/api/*']
	}
	api := RuntimeRouteRule{
		match_method: ['GET', 'HEAD']
		match_path:   ['/api/*']
	}
	assert preflight.matches_http_request('OPTIONS', '/api/posts', map[string]string{})
	assert !preflight.matches_http_request('GET', '/api/posts', map[string]string{})
	assert api.matches_http_request('GET', '/api/posts', map[string]string{})
	assert !api.matches_http_request('OPTIONS', '/api/posts', map[string]string{})
}

fn test_http_routing_runtime_matches_compiled_exchange_host_and_headers() {
	rt := HttpRoutingRuntime{
		listener_id: 'web'
		rules:       [
			RuntimeRouteRule{
				pipeline_id:   'web/admin'
				ingress_id:    'listener:web'
				match_method:  ['GET']
				match_host:    ['admin.local']
				match_path:    ['/wp-admin/*']
				match_headers: {
					'x-admin': '*'
				}
				executor:      'php'
			},
			RuntimeRouteRule{
				pipeline_id:  'web/fallback'
				ingress_id:   'listener:web'
				match_method: ['GET']
				match_path:   ['*']
				executor:     'php'
			},
		]
	}
	exchange := dispatch.http_request_exchange(dispatch.HttpIngressRequest{
		method:     'GET'
		path:       '/wp-admin/index.php'
		query:      map[string]string{}
		headers:    {
			'Host':    'admin.local'
			'X-Admin': '1'
		}
		request_id: 'req-1'
		trace_id:   'trace-1'
		ingress:    'listener:web'
	})
	rule := rt.match_compiled_http_exchange(exchange) or {
		assert false
		return
	}
	assert rule.pipeline_id == 'web/admin'

	missing_header := dispatch.http_request_exchange(dispatch.HttpIngressRequest{
		method:     'GET'
		path:       '/wp-admin/index.php'
		query:      map[string]string{}
		headers:    {
			'Host': 'admin.local'
		}
		request_id: 'req-2'
		trace_id:   'trace-2'
		ingress:    'listener:web'
	})
	fallback := rt.match_compiled_http_exchange(missing_header) or {
		assert false
		return
	}
	assert fallback.pipeline_id == 'web/fallback'
}

fn test_http_routing_runtime_preserves_first_match_order() {
	rt := HttpRoutingRuntime{
		rules: [
			RuntimeRouteRule{
				match_path: ['/api/special']
				executor:   'special'
			},
			RuntimeRouteRule{
				match_path: ['/api/*']
				executor:   'fallback'
			},
		]
	}
	rule := rt.match_http_request('GET', '/api/special', map[string]string{}) or {
		assert false
		return
	}
	assert rule.executor == 'special'
}

fn test_http_routing_runtime_owns_static_root_precedence() {
	rt := HttpRoutingRuntime{
		assets_root: '/srv/assets'
		worker_root: '/srv/worker'
	}
	assert rt.static_root(RuntimeRouteRule{
		root: '/srv/route'
	}) == '/srv/route'
	assert rt.static_root(RuntimeRouteRule{}) == '/srv/assets'
	assert HttpRoutingRuntime{
		worker_root: '/srv/worker'
	}.static_root(RuntimeRouteRule{}) == '/srv/worker'
}

fn test_route_security_header_and_query_rules() {
	rule := RuntimeRouteRule{
		required_headers:      {
			'x-api-key': '*'
			'x-mode':    'live'
		}
		denied_query_patterns: {
			'debug': '*'
			'role':  'admin'
		}
	}
	assert route_required_headers_failure(rule, {
		'x-api-key': 'secret'
		'x-mode':    'live'
	}) == ''
	assert route_required_headers_failure(rule, {
		'x-api-key': 'secret'
		'x-mode':    'preview'
	}) == 'x-mode'
	assert route_required_headers_failure(rule, {
		'x-mode': 'live'
	}) == 'x-api-key'
	assert route_denied_query_failure(rule, {
		'page': '1'
	}) == ''
	assert route_denied_query_failure(rule, {
		'debug': '1'
	}) == 'debug'
	assert route_denied_query_failure(rule, {
		'role': 'admin'
	}) == 'role'
}

fn test_route_rule_rewrite_target_preserves_original_query() {
	rule := RuntimeRouteRule{
		match_path:           ['/wp-json/*']
		rewrite:              '/index.php?rest_route=$path_remainder'
		rewrite_strip_prefix: '/wp-json'
	}
	assert rule.rewrite_target('/wp-json/wp/v2/users/me?context=edit') == '/index.php?rest_route=/wp/v2/users/me&context=edit'
	assert rule.rewrite_target('/wp-json') == '/index.php?rest_route=/'
}

fn test_route_response_cache_key_normalizes_target() {
	assert route_response_cache_key('get', '/posts?id=1') == 'GET:/posts?id=1'
	assert route_response_cache_key('HEAD', 'posts') == 'HEAD:/posts'
}

fn test_route_response_cache_bypasses_authenticated_requests() {
	rule := RuntimeRouteRule{}
	mut anon := http.Request{}
	assert route_response_cache_request_bypass_reason(rule, 'GET', anon) == ''
	mut with_cookie := http.Request{}
	with_cookie.header.set(.cookie, 'wordpress_logged_in=1')
	assert route_response_cache_request_bypass_reason(rule, 'GET', with_cookie) == 'cookie'
	mut with_auth := http.Request{}
	with_auth.header.set(.authorization, 'Bearer token')
	assert route_response_cache_request_bypass_reason(rule, 'GET', with_auth) == 'authorization'
	assert route_response_cache_request_bypass_reason(rule, 'POST', anon) == 'method'
}

fn test_route_response_cache_cookie_patterns_allow_ignored_cookies() {
	rule := RuntimeRouteRule{
		cache_bypass_cookie_patterns: ['wordpress_logged_in_*', 'wp-postpass_*']
		cache_ignore_cookie_patterns: ['wordpress_test_cookie', 'wp-settings-*']
	}
	mut with_test_cookie := http.Request{}
	with_test_cookie.header.set(.cookie, 'wordpress_test_cookie=WP%20Cookie%20check')
	assert route_response_cache_request_bypass_reason(rule, 'GET', with_test_cookie) == ''
	mut with_settings_cookie := http.Request{}
	with_settings_cookie.header.set(.cookie, 'wp-settings-1=editor')
	assert route_response_cache_request_bypass_reason(rule, 'GET', with_settings_cookie) == ''
	mut with_login_cookie := http.Request{}
	with_login_cookie.header.set(.cookie, 'wordpress_logged_in_abc=token')
	assert route_response_cache_request_bypass_reason(rule, 'GET', with_login_cookie) == 'cookie:wordpress_logged_in_abc'
	mut with_unknown_cookie := http.Request{}
	with_unknown_cookie.header.set(.cookie, 'ab_bucket=A')
	assert route_response_cache_request_bypass_reason(rule, 'GET', with_unknown_cookie) == 'cookie:ab_bucket'
}

fn test_route_response_cache_store_bypass_reason_for_delivery_outcome() {
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(200,
		map[string]string{}, 'ok')) == ''
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(204,
		map[string]string{}, '')) == 'status'
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(200, {
		'set-cookie': 'wordpress_logged_in=token'
	}, 'ok')) == 'set_cookie'
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(200, {
		'cache-control': 'private'
	}, 'ok')) == 'private'
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(200, {
		'cache-control': 'no-store'
	}, 'ok')) == 'no_store'
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(200, {
		'cache-control': 'no-cache, must-revalidate'
	}, 'ok')) == 'no_cache'
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(200, {
		'cache-control': 'public, max-age=0'
	}, 'ok')) == 'max_age_0'
	assert route_response_cache_store_bypass_reason_for_outcome(dispatch.response_outcome(200, {
		'cache-control': 'public, s-maxage=0'
	}, 'ok')) == 's_maxage_0'
}

fn test_worker_response_delivery_outcome_maps_response_values() {
	outcome := worker_response_delivery_outcome(transport.WorkerResponse{
		status:  202
		body:    'accepted'
		headers: {
			'content-type': 'text/plain'
			'x-test':       'ok'
		}
	})
	assert outcome.kind == .response
	assert outcome.status == 202
	assert outcome.body == 'accepted'
	assert outcome.headers['content-type'] == 'text/plain'
	assert outcome.headers['x-test'] == 'ok'
}

fn test_delivery_set_cookie_values_splits_non_empty_lines() {
	assert delivery_set_cookie_values('a=1\nb=2; Path=/\n\n c=3 ') == ['a=1', 'b=2; Path=/', 'c=3']
	assert delivery_set_cookie_values('') == []
}

fn test_upload_multipart_parser_extracts_file_payload() {
	body := '--abc123\r\nContent-Disposition: form-data; name="file"; filename="demo.txt"\r\nContent-Type: text/plain\r\n\r\nhello upload\r\n--abc123--\r\n'
	payload := parse_multipart_upload(body, 'multipart/form-data; boundary=abc123') or {
		panic('missing upload payload')
	}
	assert payload.filename == 'demo.txt'
	assert payload.content_type == 'text/plain'
	assert payload.body == 'hello upload'
}

fn test_upload_filename_sanitizer_keeps_basename() {
	assert sanitize_upload_filename('../../plugin zip.php') == 'plugin_zip.php'
	assert sanitize_upload_filename('') == 'upload.bin'
}

fn test_upload_completed_vjsx_handler_and_event_path() {
	assert upload_completed_vjsx_handler('vjsx:wordpress.upload.completed') == 'wordpress.upload.completed'
	assert upload_completed_vjsx_handler(' vjsx:/wordpress.upload.completed ') == '/wordpress.upload.completed'
	assert upload_completed_vjsx_handler('https://example.test/hook') == ''
	assert upload_completed_spec_from_handler('wordpress.upload.completed') == 'vjsx:wordpress.upload.completed'
	assert upload_completed_spec_from_handler('') == ''
	assert vjsx_event_path('upload.completed', 'wordpress.upload.completed') == '/__vhttpd/events/upload.completed/wordpress.upload.completed'
	assert vjsx_event_path('upload.completed', '') == '/__vhttpd/events/upload.completed'
}

fn test_route_response_headers_have_is_case_insensitive() {
	headers := {
		'Content-Type':  'text/html'
		'Cache-Control': 'public, max-age=30'
	}
	assert route_response_headers_have(headers, 'cache-control')
	assert route_response_headers_have(headers, 'CACHE-CONTROL')
	assert !route_response_headers_have(headers, 'set-cookie')
}

fn test_worker_request_payload_preserves_forwarded_https_scheme() {
	mut req := http.Request{
		method: .get
		url:    '/index.php'
		host:   '127.0.0.1:8080'
	}
	req.header.set(.x_forwarded_proto, 'https')
	raw := transport.WorkerHttpRequestCodec.encode_request('GET', '/index.php', req, '127.0.0.1',
		'trace-1', 'req-1')
	payload := json.decode(transport.WorkerRequestPayload, raw) or { panic(err) }
	assert payload.scheme == 'https'
	assert payload.port == '8080'
	assert payload.headers['x-vhttpd-trace-id'] == 'trace-1'
	assert payload.headers['x-request-id'] == 'req-1'
}

fn test_fastcgi_request_payload_includes_trace_env() {
	mut req := http.Request{
		method: .get
		url:    '/index.php'
		host:   '127.0.0.1:8080'
	}
	payload := transport.FastCgiCodec.encode_request('GET', '/index.php', '/index.php', req,
		'127.0.0.1', 'trace-cgi-1', 'req-cgi-1', {
		'VPHP_WP_ROOT': '/tmp/wp'
	})
	text := payload.bytestr()
	assert text.contains('VHTTPD_TRACE_ID')
	assert text.contains('trace-cgi-1')
	assert text.contains('VHTTPD_REQUEST_ID')
	assert text.contains('req-cgi-1')
	assert text.contains('HTTP_X_VHTTPD_TRACE_ID')
	assert text.contains('HTTP_HOST')
	assert text.contains('127.0.0.1:8080')
	assert text.contains('SERVER_NAME')
	assert text.contains('SERVER_PORT')
}

fn test_directory_slash_redirect_location() {
	tmp := os.join_path(os.temp_dir(), 'vhttpd_route_slash_test')
	os.mkdir_all(os.join_path(tmp, 'wp-admin')) or {
		assert false
		return
	}
	defer {
		os.rmdir_all(tmp) or {}
	}
	assert directory_slash_redirect_location(tmp, '/wp-admin', 'page=dashboard')? == '/wp-admin/?page=dashboard'
	assert directory_slash_redirect_location(tmp, '/wp-admin/', '') == none
	assert directory_slash_redirect_location(tmp, '/missing', '') == none
}

fn test_php_site_route_shortcuts_keep_explicit_routes_before_compat_php() {
	cfg := config.VhttpdConfig{
		php_site: config.PhpSiteConfig{
			deny_php:   ['/wp-includes/*', '/wp-config.php']
			compat_php: ['/wp-admin/*', '/xmlrpc.php']
		}
		routes:   [
			config.RouteRuleConfig{
				match:    config.RouteMatchConfig{
					path: ['/wp-includes/*']
				}
				executor: 'static'
			},
		]
	}
	routes := config.expand_php_site_routes(cfg)
	assert routes.len == 4
	assert routes[0].match.path_regexp == '^/wp-includes/.*\\.php$'
	assert routes[0].status == 403
	assert routes[1].match.path == ['/wp-config.php']
	assert routes[1].status == 403
	assert routes[2].executor == 'static'
	assert routes[3].match.path == ['/wp-admin/*', '/xmlrpc.php']
	assert routes[3].executor == 'php-cgi'
}

fn test_explicit_wp_admin_static_asset_route_wins_before_compat_php() {
	cfg := config.VhttpdConfig{
		php_site: config.PhpSiteConfig{
			compat_php: ['/wp-admin/*', '/xmlrpc.php']
		}
		routes:   [
			config.RouteRuleConfig{
				match:    config.RouteMatchConfig{
					path: ['*.css', '*.js']
				}
				executor: 'static'
			},
		]
	}
	routes := config.expand_php_site_routes(cfg)
	assert routes.len == 2
	assert routes[0].executor == 'static'
	assert routes[0].match.path == ['*.css', '*.js']
	assert routes[1].executor == 'php-cgi'
	assert routes[1].match.path == ['/wp-admin/*', '/xmlrpc.php']
}

fn test_wordpress_v2_example_projects_http_pipelines_to_runtime_routes() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	config_file := os.join_path(repo_root, 'examples', 'wordpress', 'vhttpd-v2.toml')
	plan := config.load_runtime_plan_file(config_file) or { panic(err) }
	routes := runtime_routes_from_plan(plan, 'web')
	assert routes.len >= 15

	upload := routes.filter(it.pipeline_id == 'uploads.accept')[0]
	assert upload.executor == 'upload'
	assert upload.upload_dir == '/tmp/vhttpd-wordpress-uploads'
	assert upload.on_completed == 'vjsx:wordpress.upload.completed'
	assert upload.upload_completed_transform_refs == ['transform:upload-completed']
	assert upload.max_body_bytes == 536870912
	assert upload.response_headers['X-Content-Type-Options'] == 'nosniff'

	asset := routes.filter(it.pipeline_id == 'assets.by-extension')[0]
	assert asset.executor == 'static'
	assert asset.root == '/Users/guweigang/wwwroot/wordpress'
	assert asset.cache_control == 'public, max-age=31536000, immutable'

	deny_core := routes.filter(it.pipeline_id == 'security.deny-core-files')[0]
	assert deny_core.executor == 'none'
	assert deny_core.status == 403
	assert deny_core.matches('/wp-config.php')

	compat_entrypoint := routes.filter(it.pipeline_id == 'wordpress.compat-entrypoints')[0]
	assert compat_entrypoint.executor == 'php-cgi'
	assert compat_entrypoint.matches('/wp-login.php')

	rest := routes.filter(it.pipeline_id == 'rest.pretty-route')[0]
	assert rest.executor == 'php-cgi'
	assert rest.rewrite == '/index.php?rest_route=$path_remainder'
	assert rest.rewrite_strip_prefix == '/wp-json'
	assert rest.max_body_bytes == 1048576

	front := routes.filter(it.pipeline_id == 'wordpress.front-page')[0]
	assert front.executor == 'php'
	assert front.response_cache_ttl_ms == 30000
	assert front.cache_bypass_cookie_patterns.contains('wordpress_logged_in_*')
	assert front.cache_ignore_cookie_patterns.contains('wordpress_test_cookie')
}

fn test_upload_completed_exchange_carries_upload_event_payload() {
	resp := UploadResponse{
		ok:         true
		event:      'upload.completed'
		upload_id:  'upl_1'
		filename:   'demo.txt'
		trace_id:   'trace-1'
		request_id: 'req-1'
	}
	exchange := upload_completed_exchange(resp, {
		'route': '/vhttpd/uploads'
	})
	assert exchange.identity.id == 'upl_1'
	assert exchange.identity.request_id == 'req-1'
	assert exchange.identity.trace_id == 'trace-1'
	assert exchange.kind == .event
	assert exchange.pipeline == 'upload.completed'
	assert exchange.metadata['route'] == '/vhttpd/uploads'
	match exchange.payload {
		dispatch.EventPayload {
			assert exchange.payload.topic == 'upload'
			assert exchange.payload.name == 'upload.completed'
			assert exchange.payload.data.contains('"upload_id":"upl_1"')
		}
		else {
			assert false
		}
	}
}
