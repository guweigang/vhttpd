module main

import regex
import os
import config

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

fn test_route_rule_rewrite_target_preserves_original_query() {
	rule := RuntimeRouteRule{
		match_path:           ['/wp-json/*']
		rewrite:              '/index.php?rest_route=$path_remainder'
		rewrite_strip_prefix: '/wp-json'
	}
	assert rule.rewrite_target('/wp-json/wp/v2/users/me?context=edit') == '/index.php?rest_route=/wp/v2/users/me&context=edit'
	assert rule.rewrite_target('/wp-json') == '/index.php?rest_route=/'
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
