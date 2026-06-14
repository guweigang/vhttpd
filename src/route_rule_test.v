module main

import regex

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
		re: re1
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
		re: re2
	}
	assert rule2.matches('/images/logo.png') == true
	assert rule2.matches('/avatar.png') == true
	assert rule2.matches('/style.css') == false
}
