module main

import upstream.transport
import veb
import ws

fn test_admin_context_reads_its_live_subsystem_owners() {
	mut app := &App{}
	app.lifecycle.started_at_unix = 42
	app.control_plane.http_stats.requests_total = 7
	app.engines.primary.stream_dispatch = true
	app.engines.primary.worker_backend.queue_capacity = 3
	app.websocket.state.dispatch_mode = true
	ctx := app.build_admin_context()
	assert ctx.started_at_unix() == 42
	assert ctx.http_requests_total() == 7
	assert ctx.worker_stream_dispatch()
	assert ctx.worker_queue_capacity() == 3
	assert ctx.ws_hub_dispatch_mode()
	app.control_plane.http_stats.requests_total = 8
	assert ctx.http_requests_total() == 8
}

@[heap]
struct UpstreamContextOwnerProbe {
mut:
	events           []string
	validation_error string
	request_id       string
	trace_id         string
}

fn test_upstream_registry_owns_context_without_an_app() {
	mut registry := &UpstreamRuntimeRegistry{}
	mut probe := &UpstreamContextOwnerProbe{}
	rt := registry.build_context(fn [mut probe] (kind string, _fields map[string]string) {
		probe.events << kind
	},
		fn [mut probe] (mut _ctx Context, req HttpIngressRequest, error_class string) veb.Result {
			probe.validation_error = error_class
			probe.request_id = req.request_id
			probe.trace_id = req.trace_id
			return veb.no_result()
		})
	registration := rt.register(transport.WorkerUpstreamPlanFrame{ name: 'test', transport: 'http', codec: 'ndjson' }, 'get', '/events?cursor=a', 'req', 'trace') or { panic('missing registration') }
	assert registry.active_count() == 1
	snapshot := rt.snapshot(true, 10, 0, '', 'test')
	assert snapshot.active_count == 1
	assert snapshot.sessions[0].path == '/events'
	assert snapshot.sessions[0].trace_id == 'trace'
	rt.emit('test.event', {
		'request_id': 'req'
	})
	assert probe.events == ['test.event']
	rt.unregister(registration)
	assert registry.active_count() == 0
	mut ctx := Context{}
	UpstreamRuntimeContext.execute_plan(rt, mut ctx, transport.WorkerUpstreamPlanFrame{ transport: 'unsupported' }, 'GET', '/events', 'req2', 'trace2', 0)
	assert probe.validation_error == 'unsupported_transport'
	assert probe.request_id == 'req2'
	assert probe.trace_id == 'trace2'
	plans, errors := registry.totals()
	assert plans == 1
	assert errors == 1
}

fn test_relay_carrier_context_uses_hub_without_a_kernel_or_app() {
	mut runtime := WebSocketRuntime.new(false)
	rt := runtime.build_relay_carrier_context()
	absent := rt.bind_fn('pending')
	assert !absent.send_to_fn('payload', 'text')
	assert 'pending' !in runtime.state.pending
	assert !absent.conn_open_fn()
	runtime.state.conns['pending'] = ws.HubConn{
		id:        'pending'
		lifecycle: &ws.DispatchConnState{}
	}
	target := rt.bind_fn('pending')
	assert target.send_to_fn('payload', 'text')
	assert runtime.state.pending['pending'][0].data == 'payload'
	assert target.conn_open_fn()
	assert !absent.send_to_fn('late', 'text')
	assert runtime.state.pending['pending'].len == 1
}
