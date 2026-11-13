module main

fn test_preflight_server_bind_addrs_uses_exact_configured_host() {
	assert preflight_server_bind_addrs('127.0.0.1', 19921) == ['127.0.0.1:19921']
	assert preflight_server_bind_addrs('0.0.0.0', 19921) == ['0.0.0.0:19921']
	assert preflight_server_bind_addrs('', 19921) == ['0.0.0.0:19921']
	assert preflight_server_bind_addrs('::1', 19921) == ['[::1]:19921']
	assert preflight_server_bind_addrs(' :: ', 19921) == ['[::]:19921']
	assert preflight_server_bind_addrs('[::1]', 19921) == ['[::1]:19921']
}
