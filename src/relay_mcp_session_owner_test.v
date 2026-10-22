module main

import dispatch
import executor
import net
import runtime_plan
import time
import upstream.transport
import worker

struct RelayOwnerExecutor {
	executor.DisabledLogicExecutor
	label string
	call  fn (transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse @[required]
}

fn (e RelayOwnerExecutor) provider() string { return e.label }

fn (e RelayOwnerExecutor) dispatch_mcp(mut _ executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return e.call(req)
}

fn relay_owner_executor(label string, id string, messages []string) RelayOwnerExecutor {
	return RelayOwnerExecutor{
		label: label
		call:  fn [label, id, messages] (req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
			return transport.WorkerMcpDispatchResponse{
				handled:          true
				status:           200
				session_id:       id
				protocol_version: 'owner-version'
				body:             '${label}:${req.client_capabilities_json}'
				messages:         messages
			}
		}
	}
}

fn relay_owner_publish(mut app App, value executor.LogicExecutor) &worker.WorkerState {
	state := &worker.WorkerState{ logic_executor: value }
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: state }
	app.mu.unlock()
	return state
}

fn relay_owner_exchange(id string, body string) dispatch.Exchange {
	return dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{ id: 'exchange', request_id: 'relay-request', trace_id: 'relay-trace' }
		metadata: {
			'mcp_session_id': id
		}
		payload:  dispatch.RequestPayload{ body: body }
	}
}

fn relay_owner_call(mut app App, id string, body string) RelayPipelineDispatchOutcome {
	return app.dispatch_relay_mcp_adapter(runtime_plan.AdapterPlan{}, 'mcp', relay_owner_exchange(id, body))
}

fn relay_owner_initialize_body() string {
	return '{"method":"initialize","params":{"capabilities":{"sampling":{}}}}'
}

fn test_relay_mcp_initialization_pins_route_and_capabilities_for_relay_and_http() {
	mut app := App{}
	relay_owner_publish(mut app, relay_owner_executor('old', 'owned', []))
	first := relay_owner_call(mut app, '', relay_owner_initialize_body())
	assert first.status == 200
	assert first.headers['mcp-session-id'] == 'owned'
	session := app.protocols.mcp.sessions['owned']
	assert session.dispatch != none
	assert session.client_capabilities_json.contains('"sampling"')
	relay_owner_publish(mut app, relay_owner_executor('new', 'unrelated', []))
	next := relay_owner_call(mut app, 'owned', '{"method":"tools/list"}')
	assert next.body.starts_with('old:')
	assert next.body.contains('"sampling"')
	assert next.headers['mcp-session-id'] == 'owned'
	// HTTP dispatch resolves through this same session owner.
	http_result := app.kernel_dispatch_mcp(transport.WorkerMcpDispatchRequest{ session_id: 'owned' }) or { panic(err) }
	assert http_result.body.starts_with('old:')
}

fn test_relay_mcp_existing_session_cannot_be_redirected_by_response_id() {
	mut app := App{}
	relay_owner_publish(mut app, relay_owner_executor('original', 'owned', []))
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('existing', '', '', '', '', route, false) or { panic(err) }
	outcome := relay_owner_call(mut app, 'existing', '{"method":"tools/list"}')
	assert outcome.status == 200
	assert outcome.headers['mcp-session-id'] == 'existing'
	assert app.protocols.mcp.sessions.len == 1
	assert app.protocols.mcp.sessions['existing'].request_id == 'relay-request'
}

fn test_relay_mcp_initialization_cannot_overwrite_other_route_session() {
	mut app := App{}
	relay_owner_publish(mut app, relay_owner_executor('original', 'owned', []))
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.complete_dispatch_session('owned', 'original-version', 'original-request', 'original-trace', '/mcp', route, false) or { panic(err) }
	relay_owner_publish(mut app, relay_owner_executor('candidate', 'owned', ['candidate-message']))
	outcome := relay_owner_call(mut app, '', relay_owner_initialize_body())
	assert outcome.status == 409
	assert outcome.error_class == 'relay_mcp_session_changed'
	session := app.protocols.mcp.sessions['owned']
	assert session.protocol_version == 'original-version'
	assert session.request_id == 'original-request'
	assert session.trace_id == 'original-trace'
	assert session.pending.len == 0
	assert voidptr(session.dispatch or { panic('missing original route') }) == voidptr(route)
}

fn relay_owner_wait(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('relay MCP request failed to complete')
		}
	}
}

fn test_relay_mcp_in_flight_response_cannot_recreate_deleted_or_retired_session() {
	for mode in ['delete', 'retire', 'stop'] {
		mut app := &App{}
		entered := chan bool{cap: 1}
		release := chan bool{cap: 1}
		results := chan RelayPipelineDispatchOutcome{cap: 1}
		done := chan bool{cap: 1}
		mut state := relay_owner_publish(mut app, RelayOwnerExecutor{
			label: 'blocked'
			call:  fn [entered, release] (_ transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
				entered <- true
				_ := <-release
				return transport.WorkerMcpDispatchResponse{ handled: true, session_id: 'owned', messages: ['late'] }
			}
		})
		route := app.mcp_dispatch_route('') or { panic(err) }
		app.protocols.mcp.complete_dispatch_session('owned', '', '', '', '', route, false) or { panic(err) }
		spawn fn [mut app, results, done] () {
			results <- relay_owner_call(mut app, 'owned', '{"method":"tools/list"}')
			done <- true
		}()
		relay_owner_wait(entered)
		if mode == 'delete' {
			assert app.protocols.mcp.delete_session('owned')
		} else if mode == 'retire' {
			state.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
			app.retire_mcp_dispatch_sessions()
		} else {
			app.protocols.mcp.request_stop()
		}
		release <- true
		relay_owner_wait(done)
		outcome := <-results
		assert outcome.action == 'failed'
		if session := app.protocols.mcp.sessions['owned'] {
			assert session.pending.len == 0
		}
		if mode != 'stop' {
			assert 'owned' !in app.protocols.mcp.sessions
		}
	}
}

fn test_relay_mcp_response_messages_use_retained_capabilities_and_sampling_policy() {
	message := '{"method":"sampling/createMessage"}'
	for policy in ['warn', 'drop', 'error', 'capable'] {
		mut app := App{}
		app.protocols.mcp.sampling_capability_policy = if policy == 'capable' {
			'error'
		} else {
			policy
		}
		relay_owner_publish(mut app, relay_owner_executor('owner', 'owned', [message]))
		body := if policy == 'capable' {
			relay_owner_initialize_body()
		} else {
			'{"method":"initialize"}'
		}
		outcome := relay_owner_call(mut app, '', body)
		session := app.protocols.mcp.sessions['owned']
		assert session.dispatch != none
		if policy == 'error' {
			assert outcome.status == 409
			assert outcome.error_class == 'sampling_capability_required'
			assert app.protocols.mcp.stat_sampling_capability_errors_total == 1
		} else {
			assert outcome.status == 200
		}
		if policy in ['warn', 'capable'] {
			assert session.pending == [message]
		} else {
			assert session.pending.len == 0
		}
		if policy == 'warn' {
			assert app.protocols.mcp.stat_sampling_capability_warnings_total == 1
		}
		if policy == 'drop' {
			assert app.protocols.mcp.stat_sampling_capability_dropped_total == 1
		}
	}
}

fn test_relay_mcp_generated_session_retirement_closes_its_sse_stream() {
	mut app := &App{}
	mut state := relay_owner_publish(mut app, relay_owner_executor('owner', '', []))
	outcome := relay_owner_call(mut app, '', relay_owner_initialize_body())
	id := outcome.headers['mcp-session-id']
	assert id.starts_with('mcp_')
	assert app.protocols.mcp.sessions[id].dispatch != none
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	defer { peer.close() or {} }
	conn := listener.accept() or { panic(err) }
	mut stream := app.protocols.mcp.attach_stream(id, conn) or { panic(err) }
	stream.start(fn (mut _ net.TcpConn) ! {
	}) or { panic(err) }
	done := chan bool{cap: 1}
	spawn fn [mut app, mut stream, id, done] () {
		app.protocols.mcp.run_stream(id, mut stream)
		done <- true
	}()
	state.stop_backend(executor.disabled_executor_lifecycle(), worker.LifecyclePort{})
	app.retire_mcp_dispatch_sessions()
	relay_owner_wait(done)
	assert stream.finished()
	assert app.protocols.mcp.active_streams() == 0
	assert id !in app.protocols.mcp.sessions
}

fn test_shared_mcp_completion_rejects_stopped_owner_without_publishing() {
	mut app := App{}
	relay_owner_publish(mut app, relay_owner_executor('owner', '', []))
	route := app.mcp_dispatch_route('') or { panic(err) }
	app.protocols.mcp.request_stop()
	if _ := McpRuntime.complete_dispatch_session(mut app.protocols.mcp, transport.WorkerMcpDispatchRequest{
		body: relay_owner_initialize_body()
	}, transport.WorkerMcpDispatchResponse{}, route) {
		assert false
	} else {
		assert err.msg() == 'mcp_stopping'
	}
	assert app.protocols.mcp.sessions.len == 0
}
