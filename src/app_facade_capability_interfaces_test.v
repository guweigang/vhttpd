module main

import executor

fn test_app_facade_reads_live_configuration_after_creation() {
	mut app := App{}
	app.protocols.runtime_config_json = '{"generation":1}'
	app.protocols.runtime_plan_json = '{"version":2,"generation":1}'
	facade := app.as_facade()
	app.protocols.runtime_config_json = '{"generation":2}'
	app.protocols.runtime_plan_json = '{"version":2,"generation":2}'
	assert facade.get_runtime_config_json() == app.protocols.runtime_config_json
	assert facade.get_runtime_plan_json() == app.protocols.runtime_plan_json
}

fn test_app_facade_updates_original_app_counters() {
	mut app := App{}
	mut facade := app.as_facade()
	facade.emit('http.request', {
		'status': '503'
		'error_class': 'timeout'
	})
	assert app.control_plane.http_stats.requests_total == 1
	assert app.control_plane.http_stats.errors_total == 1
	assert app.control_plane.http_stats.timeouts_total == 1
}

fn accepts_runtime_config_facade(f executor.RuntimeConfigFacade) bool {
	return f.get_runtime_config_json() != ''
}

fn accepts_worker_backend_config_facade(f executor.WorkerBackendConfigFacade) bool {
	return f.worker_backend_sockets_len() >= 0
}

fn accepts_worker_socket_facade(mut f executor.WorkerSocketFacade) bool {
	f.on_worker_request_started('/tmp/noop.sock')
	f.on_worker_request_finished('/tmp/noop.sock')
	f.on_worker_request_released('/tmp/noop.sock')
	return true
}

fn accepts_stream_dispatch_facade(mut f executor.WorkerStreamDispatchFacade) bool {
	_ = f
	return true
}

fn accepts_mcp_dispatch_facade(mut f executor.WorkerMcpDispatchFacade) bool {
	_ = f
	return true
}

fn accepts_websocket_dispatch_facade(mut f executor.WorkerWebSocketDispatchFacade) bool {
	_ = f.execute_websocket_dispatch_commands_result([])
	return true
}

fn accepts_platform_facade(mut f executor.PlatformFacade) bool {
	f.emit('test.event', {
		'ok': 'true'
	})
	return true
}

fn accepts_provider_bridge_facade(mut f executor.ProviderBridgeFacade) bool {
	_ = f
	return true
}

fn accepts_command_dispatch_facade(mut f executor.CommandDispatchFacade) bool {
	_ = f.run_command_envelopes('req-1', executor.DispatchContext{}, [])
	return true
}

fn test_noop_app_facade_satisfies_capability_interfaces() {
	mut facade := executor.NoOpAppFacade{}
	assert accepts_runtime_config_facade(facade)
	assert accepts_worker_backend_config_facade(facade)
	assert accepts_worker_socket_facade(mut facade)
	assert accepts_stream_dispatch_facade(mut facade)
	assert accepts_mcp_dispatch_facade(mut facade)
	assert accepts_websocket_dispatch_facade(mut facade)
	assert accepts_platform_facade(mut facade)
	assert accepts_provider_bridge_facade(mut facade)
	assert accepts_command_dispatch_facade(mut facade)
}

fn test_app_facade_worker_dispatch_ports_satisfy_capability_interfaces() {
	facade := executor.NoOpAppFacade{}

	config_port := executor.worker_backend_config_port(facade)
	assert accepts_worker_backend_config_facade(config_port)

	mut socket_port := executor.worker_socket_port(facade)
	assert accepts_worker_socket_facade(mut socket_port)

	mut stream_port := executor.worker_stream_dispatch_port(facade)
	assert accepts_stream_dispatch_facade(mut stream_port)

	mut mcp_port := executor.worker_mcp_dispatch_port(facade)
	assert accepts_mcp_dispatch_facade(mut mcp_port)

	mut websocket_port := executor.worker_websocket_dispatch_port(facade)
	assert accepts_websocket_dispatch_facade(mut websocket_port)
}
