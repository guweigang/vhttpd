module main

import api.openai
import config
import net
import runtime_plan
import time

fn protocol_reload_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	peer := net.dial_tcp(addr.str()) or { panic(err) }
	conn := listener.accept() or { panic(err) }
	return conn, peer
}

fn test_protocol_reload_keeps_registered_streams_pending_messages_and_metrics() {
	mut hub := ProtocolRuntimeHub.from_plan(config.VhttpdConfig{}, runtime_plan.RuntimePlan{}, 'web')
	hub.mcp.ensure_session('retained', 'version', 'req', 'trace', '/mcp')
	conn, mut peer := protocol_reload_pair()
	defer { peer.close() or {} }
	mut stream := hub.mcp.attach_stream('retained', conn) or { panic(err) }
	defer { hub.mcp.finish_stream('retained', mut stream) }
	assert hub.mcp.do_queue('retained', '{"queued":true}').queued
	hub.mcp.stat_sessions_evicted_total = 7
	base := protocol_runtime_plan_update_from_plan(runtime_plan.RuntimePlan{}, 'web')
	mut next_mcp := base.mcp
	next_mcp.max_sessions = 2
	next_mcp.max_pending_messages = 1
	next_mcp.session_ttl_seconds = 42
	next_mcp.allowed_origins = ['https://example.test']
	next_mcp.sampling_capability_policy = 'drop'
	update := ProtocolRuntimePlanUpdate{ ...base, mcp: next_mcp }
	for _ in 0 .. 2 { hub.apply_plan_update(update) }
	assert hub.mcp.active_streams() == 1
	assert !stream.stopped()
	assert hub.mcp.sessions['retained'].pending == ['{"queued":true}']
	assert hub.mcp.sessions['retained'].trace_id == 'trace'
	assert hub.mcp.stat_sessions_evicted_total == 7
	assert hub.mcp.max_sessions == 2
	assert hub.mcp.session_ttl_seconds == 42
	assert hub.mcp.origin_allowed({
		'origin': 'https://example.test'
	})
	assert !hub.mcp.origin_allowed({
		'origin': 'https://elsewhere.test'
	})
	assert hub.mcp.sampling_capability_policy == 'drop'
	assert hub.mcp.do_queue('retained', 'new').queued
	assert hub.mcp.sessions['retained'].pending == ['new']
	assert hub.mcp.stat_pending_dropped_total == 1
	other, mut other_peer := protocol_reload_pair()
	defer { other_peer.close() or {} }
	mut replacement := hub.mcp.attach_stream('retained', other) or { panic(err) }
	defer { hub.mcp.finish_stream('retained', mut replacement) }
	assert stream.stopped()
	assert hub.mcp.active_streams() == 2
	hub.mcp.finish_stream('retained', mut stream)
	assert hub.mcp.active_streams() == 1
	hub.mcp.request_stop()
	assert replacement.stopped()
	hub.mcp.finish_stream('retained', mut replacement)
	hub.mcp.wait_stopped()
}

fn test_protocol_reload_cannot_reopen_stopped_mcp_owner() {
	mut hub := ProtocolRuntimeHub.from_plan(config.VhttpdConfig{}, runtime_plan.RuntimePlan{}, 'web')
	hub.mcp.ensure_session('retained', '', '', '', '')
	hub.mcp.request_stop()
	hub.apply_plan_update(protocol_runtime_plan_update_from_plan(runtime_plan.RuntimePlan{}, 'web'))
	conn, mut peer := protocol_reload_pair()
	defer { peer.close() or {} }
	if mut unexpected := hub.mcp.attach_stream('retained', conn) {
		hub.mcp.finish_stream('retained', mut unexpected)
		panic('reload reopened terminal MCP owner')
	} else {
		assert err.msg() == 'mcp_stopping'
		mut borrowed := conn
		borrowed.close() or {}
	}
}

fn test_protocol_reload_preserves_original_response_store_and_expiry() {
	mut hub := ProtocolRuntimeHub.from_plan(config.VhttpdConfig{}, runtime_plan.RuntimePlan{}, 'web')
	mut store := &hub.openai.responses
	store.set('saved', openai.OpenAIResponseRecord{ id: 'saved', body: 'response' }) or { panic(err) }
	store.set_with_ttl('expired', openai.OpenAIResponseRecord{ id: 'expired' }, time.millisecond) or { panic(err) }
	base := protocol_runtime_plan_update_from_plan(runtime_plan.RuntimePlan{}, 'web')
	mut next_openai := base.openai
	next_openai.enabled = true
	next_openai.base_path = '/new-api'
	next_openai.default_backend = 'next'
	update := ProtocolRuntimePlanUpdate{ ...base, openai: next_openai }
	hub.apply_plan_update(update)
	assert hub.openai.enabled
	assert hub.openai.base_path == '/new-api'
	assert hub.openai.default_backend == 'next'
	saved := hub.openai.responses.get('saved') or { panic(err) }
	assert saved.body == 'response'
	store.set('after', openai.OpenAIResponseRecord{ id: 'after' }) or { panic(err) }
	assert hub.openai.responses.exists('after')
	hub.openai.responses.delete('saved') or { panic(err) }
	assert !store.exists('saved')
	time.sleep(3 * time.millisecond)
	assert !hub.openai.responses.exists('expired')
}

fn test_concurrent_reload_and_message_queue_share_the_existing_mcp_owner() {
	mut app := &App{}
	app.protocols.mcp.ensure_session('queue', '', '', '', '')
	base := protocol_runtime_plan_update_from_plan(runtime_plan.RuntimePlan{}, 'web')
	mut settings := base.mcp
	settings.max_pending_messages = 1
	update := ProtocolRuntimePlanUpdate{ ...base, mcp: settings }
	app.protocols.apply_plan_update(update)
	assert McpRuntime.queue_message(mut app, 'queue', 'seed').queued
	done := chan bool{cap: 2}
	spawn fn [mut app, done] () {
		for _ in 0 .. 1000 {
			assert McpRuntime.queue_message(mut app, 'queue', 'next').queued
		}
		done <- true
	}()
	spawn fn [mut app, update, done] () {
		for _ in 0 .. 1000 {
			app.mu.@lock()
			app.protocols.apply_plan_update(update)
			app.mu.unlock()
		}
		done <- true
	}()
	for _ in 0 .. 2 {
		select {
			_ := <-done {
			}
			3 * time.second {
				panic('reload and queue did not finish')
			}
		}
	}
	assert app.protocols.mcp.sessions['queue'].pending == ['next']
	assert app.protocols.mcp.stat_pending_dropped_total == 1000
}
