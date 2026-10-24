module executor

import os
import vjsx
import net.http
import upstream.transport

// No worker configuration, socket selection, or transport dispatch methods.
struct EmbeddedOnlyHost {
mut:
	config_json string
	events      int
	creations   int
}

fn (h EmbeddedOnlyHost) get_runtime_config_json() string { return h.config_json }

fn (_ EmbeddedOnlyHost) get_runtime_plan_json() string { return '{"version":2}' }

fn (mut h EmbeddedOnlyHost) emit(_kind string, _fields map[string]string) { h.events++ }

fn (mut _ EmbeddedOnlyHost) admin_runtime_snapshot() AdminRuntimeSummary {
	return AdminRuntimeSummary{}
}

fn (mut _ EmbeddedOnlyHost) provider_bridge_dispatch_callback(_provider string, _app string, _trace string, _summary FeishuRuntimeEventSummary, _payload string) !FeishuCardBridgeResult {
	return FeishuCardBridgeResult{}
}

fn (mut _ EmbeddedOnlyHost) run_command_envelopes(_request string, _ctx DispatchContext, _commands []transport.WorkerWebSocketUpstreamCommand) string {
	return ''
}

fn (mut _ EmbeddedOnlyHost) execute_websocket_dispatch_commands_result(_commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	return transport.WorkerWebSocketDispatchCommandsResult{}
}

fn test_embedded_http_runs_with_only_embedded_services_and_live_config() {
	dir := os.join_path(os.temp_dir(), 'vhttpd_embedded_only_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	entry := os.join_path(dir, 'handler.js')
	os.write_file(entry, 'globalThis.__vhttpd_handle = (ctx) => { ctx.runtime.emit("embedded.test", {}); return ctx.json({ value: ctx.runtime.config("message") }, 201); };') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       entry
		runtime_profile: 'script'
	})
	defer { exec.close() }
	mut host := &EmbeddedOnlyHost{ config_json: '{"message":"first"}' }
	request := HttpLogicDispatchRequest{
		method:     'GET'
		path:       '/embedded'
		req:        http.Request{ method: .get, url: '/embedded', host: 'example.test' }
		request_id: 'embedded-1'
		trace_id:   'trace-1'
	}
	first := exec.dispatch_http_with_host(mut host, request) or { panic(err) }
	assert first.response.status == 201
	assert first.response.body.contains('first')
	host.config_json = '{"message":"second"}'
	second := exec.dispatch_http_with_host(mut host, request) or { panic(err) }
	assert second.response.body.contains('second')
	assert host.events == 2
}

fn test_request_host_lookup_absence_priority_and_request_end() {
	mut state := &VjsxExecutorState{
		hosts: [VjsxLaneHost.empty()]
		lanes: [VjsxExecutionLane{ id: 'lane_0' }]
	}
	for mode in [InProcVjsxHostFallback.request_only, .lane, .executor] {
		assert state.request_host(0, mode) == none
		assert state.request_host(-1, mode) == none
		assert state.request_host(1, mode) == none
	}
	assert state.remembered_host() == none
	exec := InProcVjsxExecutor{ state: state }
	mut global_host := &EmbeddedOnlyHost{ config_json: 'global' }
	mut request_host := &EmbeddedOnlyHost{ config_json: 'request' }
	exec.remember_app(mut global_host)
	exec.activate_lane_request_context(0, mut request_host, 'lane_0', HttpLogicDispatchRequest{
		request_id: 'request-1'
		trace_id:   'trace-1'
		method:     'post'
		path:       '/hello?query=1'
	})
	for mode in [InProcVjsxHostFallback.request_only, .lane, .executor] {
		access := state.request_host(0, mode) or { panic('missing request host') }
		assert access.host.get_runtime_config_json() == 'request'
		assert access.context.trace_id == 'trace-1'
		assert access.context.method == 'POST'
		assert access.context.path == '/hello'
		assert access.lane_id == 'lane_0'
	}
	// A captured host remains usable after unlock and observes host mutations.
	access := state.request_host(0, .request_only) or { panic('missing') }
	request_host.config_json = 'updated'
	exec.clear_lane_request_context(0)
	assert access.host.get_runtime_config_json() == 'updated'
	assert access.context.request_id == 'request-1'
	assert state.request_host(0, .request_only) == none
	lane_access := state.request_host(0, .lane) or { panic('missing lane host') }
	assert lane_access.host.get_runtime_config_json() == 'updated'
	assert !lane_access.context.active
	assert lane_access.context.trace_id == ''
	global_access := state.request_host(0, .executor) or { panic('missing executor host') }
	assert global_access.host.get_runtime_config_json() == 'global'
	assert global_access.lane_id == 'lane_0'
	assert state.request_host(-1, .lane) == none
	assert state.request_host(1, .lane) == none
	invalid_lane := state.request_host(-1, .executor) or { panic('missing global fallback') }
	assert invalid_lane.lane_id == ''
	state.hosts[0].destroy()
	assert state.request_host(0, .lane) == none
	assert state.request_host(0, .request_only) == none
}

fn test_embedded_host_callbacks_report_absence_and_expired_request() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	mut ctx := session.context()
	mut state := &VjsxExecutorState{
		hosts: [VjsxLaneHost.empty()]
		lanes: [VjsxExecutionLane{ id: 'lane_0' }]
	}
	InProcVjsxHostApi.install(mut ctx, mut state, 0)
	empty := ctx.eval('JSON.stringify({creation: vhttpdHost.issueFeishuStream("stream", "main"), config: vhttpdHost.config(), emitted: vhttpdHost.emit("test"), snapshot: typeof vhttpdHost.snapshot(), bridge: vhttpdHost.bridgeDispatch("{}"), websocket: vhttpdHost.websocketDispatch("{}")})') or { panic(err) }
	defer { empty.free() }
	assert empty.to_string().contains('"creation":""')
	assert empty.to_string().contains('"config":""')
	assert empty.to_string().contains('"emitted":false')
	assert empty.to_string().contains('"snapshot":"undefined"')
	assert empty.to_string().contains('bridge_dispatch_app_missing')
	assert empty.to_string().contains('websocket_dispatch_app_missing')
	exec := InProcVjsxExecutor{ state: state }
	mut host := &EmbeddedOnlyHost{ config_json: '{"message":"live"}' }
	exec.remember_app(mut host)
	exec.activate_lane_request_context(0, mut host, 'lane_0', HttpLogicDispatchRequest{ trace_id: 'trace' })
	live := ctx.eval('vhttpdHost.emit("test")') or { panic(err) }
	defer { live.free() }
	assert live.to_bool()
	assert host.events == 1
	creation := ctx.eval('vhttpdHost.issueFeishuStream("stream", "main")') or { panic(err) }
	defer { creation.free() }
	assert creation.to_string() == 'stream:main'
	assert host.creations == 1
	exec.clear_lane_request_context(0)
	expired := ctx.eval('JSON.stringify({creation: vhttpdHost.issueFeishuStream("stream", "main"), config: vhttpdHost.config(), emitted: vhttpdHost.emit("test"), snapshot: typeof vhttpdHost.snapshot(), bridge: vhttpdHost.bridgeDispatch("{}"), websocket: vhttpdHost.websocketDispatch("{}")})') or { panic(err) }
	defer { expired.free() }
	assert expired.to_string().contains('"creation":""')
	assert host.creations == 1
	assert expired.to_string().contains('"config":""')
	assert expired.to_string().contains('"emitted":false')
	assert expired.to_string().contains('"snapshot":"string"')
	assert expired.to_string().contains('bridge_dispatch_app_missing')
	assert !expired.to_string().contains('websocket_dispatch_app_missing')
	assert host.events == 1
}

fn (mut h EmbeddedOnlyHost) issue_feishu_stream_creation(stream_id string, app_name string, message_id string) !string {
	h.creations++
	return stream_id + ':' + app_name
}
