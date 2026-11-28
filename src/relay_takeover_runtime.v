module main

import crypto.rand
import app_bundle
import os
import dispatch
import executor
import json2 as json
import net.http
import relay
import runtime_plan
import takeover
import time
import ws

struct TakeoverRequest {
 local_engine_id string
 application_id string
 installation_id string
	app_id  string
	account string
	method  string
	path    string
	body    string
	headers map[string]string
}

struct TakeoverResponse {
	handled bool
	status  int
	body    string
	headers map[string]string
}

struct TakeoverControl {
 application_id string
 installation_id string
 component string
 local_engine_id string
	action   string
	relay_id string
	route    string = 'debug/control'
	app_id   string
	accounts []string
	lease_id string
	ttl_ms   int = 900000
}

struct TakeoverStatus {
 binding_protocol int
 application_id string
 installation_id string
	local_in_flight int
	active          bool
	lease_id        string
	app_id          string
	accounts        []string
	expires_ms      i64
}

fn takeover_function_path(path string) bool {
	if !path.starts_with('/functions/') { return false }
	name := path.all_after('/functions/')
	return name.len > 0 && name.len <= 64 && name[0].is_letter() && name.bytes().all(it.is_alnum() || it in [
		`_`,
		`-`,
	])
}

// Called only from trusted JS after its authentication step. This interface is
// deliberately not an HTTP endpoint accepting an identity from the client.
pub fn (mut app App) vjsx_takeover_request(raw string) !string {
 return app.vjsx_takeover_request_owned(raw,'','')
}

pub fn (mut app App) vjsx_takeover_identity_required() bool {
 mut registry := app.takeovers
 if lease := registry.status(time.now().unix_milli()) {return lease.application_id != ''}
 return false
}

pub fn (mut app App) vjsx_takeover_request_owned(raw string, application_id string, installation_id string) !string {
	mut registry := app.takeovers
	if registry.status(time.now().unix_milli()) == none { return '{"handled":false}' }
	decoded := json.decode[TakeoverRequest](raw)!
 input := TakeoverRequest{...decoded,application_id:application_id,installation_id:installation_id}
	lease := registry.admit_identity(input.app_id,input.account,input.application_id,input.installation_id,time.now().unix_milli())!
	if lease.id == '' { return '{"handled":false}' }
	defer { registry.finish() }
	if raw.len > 2097152 {
		return json.encode(TakeoverResponse{ handled: true, status: 413, headers: {
			'content-type': 'application/json'
		}, body: '{"error":{"code":"DEBUG_REQUEST_TOO_LARGE"}}' })
	}
	if input.method != 'POST' || !takeover_function_path(input.path) {
		return error('takeover_path_forbidden')
	}
	forward := if lease.application_id != '' {json.encode(TakeoverRequest{...input,local_engine_id:lease.local_engine_id})} else {raw}
 response := app.request_takeover_relay(lease.relay_id, lease.route, forward, 60000, lease.binding)!
	if response.body.len > 2097152 { return error('takeover_response_limit') }
	return json.encode(TakeoverResponse{ handled: true, status: response.status, headers: response.headers, body: response.body })
}

// One send, one attachment, no retries or remote execution on uncertain result.
fn (mut app App) request_takeover_relay(relay_id string, route string, body string, timeout_ms int, binding relay.CarrierDispatchPlan) !dispatch.DeliveryOutcome {
	id := 'debug-' + rand.bytes(16)!.hex()
	clock := time.new_stopwatch()
	input := json.decode[TakeoverRequest](body) or { TakeoverRequest{} }
	mut fields := {'relay_id': relay_id, 'route': route, 'channel_id': id, 'request_id': id,
		'trace_id': id, 'execution': 'remote_to_local', 'path': input.path, 'method': input.method,
		'request_bytes': body.len.str(), 'phase': 'started'}
	observed := route != 'debug/control'
	if observed { app.emit('relay.takeover.forward', fields) }
	result := app.request_takeover_relay_once(relay_id, route, body, timeout_ms, binding, id) or {
		if observed {
			fields['phase'] = 'completed'; fields['status'] = '502'
			fields['duration_ms'] = clock.elapsed().milliseconds().str()
			fields['error_class'] = 'result_unknown_no_replay'
			app.emit('relay.takeover.forward', fields)
		}
		return err
	}
	if observed {
		fields['phase'] = 'completed'; fields['status'] = result.status.str()
		fields['response_bytes'] = result.body.len.str()
		fields['duration_ms'] = clock.elapsed().milliseconds().str()
		app.emit('relay.takeover.forward', fields)
	}
	return result
}

fn (mut app App) request_takeover_relay_once(relay_id string, route string, body string, timeout_ms int, binding relay.CarrierDispatchPlan, id string) !dispatch.DeliveryOutcome {
	outcome := dispatch.relay_delivery_outcome_with_completion('relay:${relay_id}', {
		'frame_kind': 'open'
		'frame_id':   id
		'channel_id': id
		'trace_id':   id
		'request_id': id
		'route':      route
		'body':       body
	}, 'wait', timeout_ms)
	outbound := app.relay.prepare_outbound_delivery(outcome)
	if outbound.action != .ready || !binding.is_current() || outbound.carrier_id != binding.carrier_id {
		return error('takeover_connection_changed')
	}
	tracking := app.relay.track_outbound_delivery(outbound, 4)
	if tracking.action == .rejected { return error('takeover_tracking_failed') }
	defer { app.relay.finish_outbound_delivery(outbound) }
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), outbound.carrier_id)
	sent := relay.send_to_carrier(mut carrier, outbound)
	if !sent.ok { return error('takeover_result_unknown') }
	clock := time.new_stopwatch()
	for clock.elapsed().milliseconds() < timeout_ms {
		if !outbound.plan.is_current() || !binding.is_current() {
			return error('takeover_connection_lost_result_unknown')
		}
		completion := app.relay.response_completion_after_send(outbound, sent)
		if completion.action == .completed { return completion.delivery }
		if completion.action == .failed { return error('takeover_remote_failed_result_unknown') }
		time.sleep(time.millisecond)
	}
	return error('takeover_timeout_result_unknown')
}

fn (mut app App) dispatch_takeover_control(view PipelineDispatchView, adapter runtime_plan.AdapterPlan, exchange dispatch.Exchange) RelayPipelineDispatchOutcome {
	binding := relay.carrier_dispatch_plan(app.relay.carriers, exchange.metadata['relay_id'], relay.WireFrame{})
	descriptor := view.plan.relays[binding.relay_id] or { return relay_pipeline_failure(exchange, 403, 'takeover_forbidden', 'takeover_forbidden') }
	if descriptor.mode != 'hub' || descriptor.options.strings['token'] == '' || binding.carrier_id != exchange.metadata['carrier_id'] || !binding.is_current() {
		return relay_pipeline_failure(exchange, 403, 'takeover_forbidden', 'takeover_forbidden')
	}
	body := relay_pipeline_exchange_body(exchange)
	if body.len > 8192 {
		return relay_pipeline_failure(exchange, 413, 'takeover_limit', 'takeover_limit')
	}
	input := json.decode[TakeoverControl](body) or { return relay_pipeline_failure(exchange, 400, 'takeover_invalid_control', 'takeover_invalid_control') }
	mut registry := app.takeovers
	now := time.now().unix_milli()
	if input.action == 'start' {
        if input.application_id != '' || input.installation_id != '' {
            record := app_bundle.read_installation(os.dir(view.plan.source.config_path),input.component) or {return relay_pipeline_failure(exchange,409,'application_binding_mismatch','application_binding_mismatch')}
            if record.app_id != input.application_id || record.id != input.installation_id {return relay_pipeline_failure(exchange,409,'application_binding_mismatch','application_binding_mismatch')}
        }
		if input.ttl_ms < 1000 || input.ttl_ms > 900000 {
			return relay_pipeline_failure(exchange, 400, 'takeover_invalid_ttl', 'takeover_invalid_ttl')
		}
		id := rand.bytes(16) or { return relay_pipeline_failure(exchange, 500, 'takeover_random_failed', 'takeover_random_failed') }
		registry.start(takeover.Lease{
			application_id:input.application_id
            installation_id:input.installation_id
            local_engine_id:input.local_engine_id
            id:         id.hex()
			app_id:     input.app_id
			accounts:   input.accounts
			relay_id:   binding.relay_id
			route:      adapter.options.strings['route']
			binding:    binding
			expires_ms: now + input.ttl_ms
		}, now) or { return relay_pipeline_failure(exchange, 409, err.msg(), 'takeover_start_failed') }
	} else if input.action == 'stop' {
		registry.stop(input.lease_id, binding.carrier_id) or { return relay_pipeline_failure(exchange, 409, err.msg(), 'takeover_stop_failed') }
	} else if input.action != 'status' {
		return relay_pipeline_failure(exchange, 400, 'takeover_invalid_action', 'takeover_invalid_action')
	}
	mut status := TakeoverStatus{binding_protocol:2}
	if lease := registry.status(now) {
		if lease.binding.carrier_id != binding.carrier_id {
			return relay_pipeline_failure(exchange, 409, 'takeover_owned_elsewhere', 'takeover_owned_elsewhere')
		}
		status = TakeoverStatus{ binding_protocol:2, application_id:lease.application_id,installation_id:lease.installation_id, active: true, lease_id: lease.id, app_id: lease.app_id, accounts: lease.accounts, expires_ms: lease.expires_ms }
	}
	return relay_pipeline_success_with_body(exchange, 'response', 200, json.encode(status), {})
}

fn (mut app App) dispatch_takeover_http(view PipelineDispatchView, adapter runtime_plan.AdapterPlan, exchange dispatch.Exchange) RelayPipelineDispatchOutcome {
	clock := time.new_stopwatch()
	raw := relay_pipeline_exchange_body(exchange)
	input := if raw.len <= 2097152 { json.decode[TakeoverRequest](raw) or { TakeoverRequest{} } } else { TakeoverRequest{} }
	mut fields := {'relay_id': exchange.metadata['relay_id'], 'channel_id': exchange.metadata['channel_id'],
		'route': exchange.pipeline, 'trace_id': exchange.identity.trace_id, 'request_id': exchange.identity.request_id,
		'path': if takeover_function_path(input.path) { input.path } else { '' }, 'method': input.method,
		'execution': 'local', 'phase': 'started', 'request_bytes': raw.len.str()}
	app.emit('relay.takeover.execute', fields)
	result := app.dispatch_takeover_http_once(view, adapter, exchange)
	fields['phase'] = 'completed'; fields['status'] = result.status.str()
	fields['duration_ms'] = clock.elapsed().milliseconds().str()
	fields['response_bytes'] = result.body.len.str()
	fields['error_class'] = result.error_class
	app.emit('relay.takeover.execute', fields)
	return result
}

fn (mut app App) dispatch_takeover_http_once(view PipelineDispatchView, adapter runtime_plan.AdapterPlan, exchange dispatch.Exchange) RelayPipelineDispatchOutcome {
	binding := relay.carrier_dispatch_plan(app.relay.carriers, exchange.metadata['relay_id'], relay.WireFrame{})
	descriptor := view.plan.relays[binding.relay_id] or { return relay_pipeline_failure(exchange, 403, 'takeover_forbidden', 'takeover_forbidden') }
	if descriptor.mode != 'agent' || descriptor.options.strings['token'] == '' || binding.carrier_id != exchange.metadata['carrier_id'] || !binding.is_current() {
		return relay_pipeline_failure(exchange, 403, 'takeover_forbidden', 'takeover_forbidden')
	}
	body := relay_pipeline_exchange_body(exchange)
	if body.len > 2097152 {
		return relay_pipeline_failure(exchange, 413, 'takeover_request_limit', 'takeover_request_limit')
	}
	input := json.decode[TakeoverRequest](body) or { return relay_pipeline_failure(exchange, 400, 'takeover_invalid_request', 'takeover_invalid_request') }
	mut registry := app.takeovers
	registry.begin_execution() or { return relay_pipeline_failure(exchange, 429, 'takeover_busy', 'takeover_busy') }
	defer { registry.finish() }
	if input.method != 'POST' || !takeover_function_path(input.path) {
		return relay_pipeline_failure(exchange, 403, 'takeover_path_forbidden', 'takeover_path_forbidden')
	}
	mut req := http.Request{ method: .post, url: input.path, data: input.body, host: 'vhttpd.internal' }
	req.header.set(.content_type, 'application/json')
	// Identity is reauthenticated by the ordinary local application using the
	// remote session DB. Never trust the envelope's account as a wx context.
	req.header.set(.authorization, input.headers['authorization'])
	engine := adapter.engine or { return relay_pipeline_failure(exchange, 500, 'takeover_engine_missing', 'takeover_engine_missing') }
	if input.application_id != '' {
        if input.local_engine_id != engine.id {return relay_pipeline_failure(exchange,409,'application_binding_mismatch','application_binding_mismatch')}
        meta := app_bundle.engine_manifest(view.plan.source.config_path,engine.id) or {return relay_pipeline_failure(exchange,409,'application_binding_mismatch','application_binding_mismatch')}
        if meta.id != input.application_id {return relay_pipeline_failure(exchange,409,'application_binding_mismatch','application_binding_mismatch')}
    }
 selection := view.engines.dispatch_selection(engine.id)
	mut facade := app.as_facade()
	mut response := selection.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{
		method:        'POST'
		path:          input.path
		original_path: input.path
		req:           req
		trace_id:      exchange.identity.trace_id
		request_id:    exchange.identity.request_id
	}) or { return relay_pipeline_failure(exchange, 502, 'takeover_execution_failed', 'takeover_execution_failed') }
	defer {
		response.close_live_conn()
		response.finish_worker()
	}
	if response.kind != .response || response.response.body.len > 2097152 {
		return relay_pipeline_failure(exchange, 502, 'takeover_response_unsupported', 'takeover_response_unsupported')
	}
	mut headers := map[string]string{}
	for key, value in response.response.headers {
		if key.to_lower() in ['content-type', 'cache-control'] { headers[key.to_lower()] = value }
	}
	headers['x-vhttpd-execution'] = 'local'
	return relay_pipeline_success_with_body(exchange, 'response', response.response.status, response.response.body, headers)
}
