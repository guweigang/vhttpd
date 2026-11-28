module main

import crypto.rand
import dbx
import dispatch
import executor
import json2 as json
import relay
import relaydb
import runtime_plan
import time
import ws

@[heap]
struct RelayDatabaseConnection {
	app &App @[required]
	relay_id string
	route string
	binding relay.CarrierDispatchPlan
}

fn (connection RelayDatabaseConnection) is_current() bool {
	return connection.binding.is_current()
}

fn (connection RelayDatabaseConnection) send(body string, timeout_ms int, cancelled fn () bool) !string {
	mut app := connection.app
	return app.request_relay_database(connection.relay_id, connection.route, body, timeout_ms, connection.binding, cancelled)
}

fn (mut app App) relay_database_backend(resource runtime_plan.ResourcePlan) !executor.DatabaseBackend {
	ref := runtime_plan.parse_ref(resource.options.strings['relay'])!
	if ref.domain != .relay { return error('relay_db_invalid_relay_reference') }
	view := app.pipeline_dispatch_view()
	descriptor := view.plan.relays[ref.id] or { return error('relay_db_unknown_relay') }
	if descriptor.mode != 'agent' || descriptor.options.strings['token'] == '' || resource.kind != 'mysql' { return error('relay_db_requires_authenticated_mysql_agent') }
	route := resource.options.strings['route']
	remote := resource.options.strings['remote_resource']
	if route == '' || !remote.starts_with('db/') { return error('relay_db_missing_resource_route') }
	mut client := relaydb.RecoveringClient.new(remote, fn [mut app, ref, route] () !relaydb.Connection {
		// Mint a generation against an already identified attachment. Lazy
		// binding could let concurrent first calls straddle a reconnect.
		binding := relay.carrier_dispatch_plan(app.relay.carriers, ref.id, relay.WireFrame{})
		if !binding.is_current() { return error('relay_db_unavailable') }
		return &RelayDatabaseConnection{app: app, relay_id: ref.id, route: route, binding: binding}
	})
	return executor.DatabaseBackend{
		run_fn: fn [mut client] (body string, cancelled fn () bool) !string { return client.run_json(body, cancelled) }
		close_fn: fn [mut client] () { client.close() }
	}
}

fn (mut app App) request_relay_database(relay_id string, route string, body string, timeout_ms int, binding relay.CarrierDispatchPlan, cancelled fn () bool) !string {
	id := 'rdb-' + rand.bytes(16)!.hex()
	clock := time.new_stopwatch()
	envelope := json.decode[relaydb.Envelope](body) or { relaydb.Envelope{} }
	mut fields := {'relay_id': relay_id, 'route': route, 'channel_id': id,
		'request_id': envelope.request.request_id, 'trace_id': envelope.request.trace_id,
		'execution': 'remote_resource', 'resource': envelope.resource,
		'operation': envelope.request.op, 'driver': 'mysql', 'phase': 'started'}
	app.emit('relay.database.request', fields)
	response := app.request_relay_database_once(relay_id, route, body, timeout_ms, binding, cancelled, id) or {
		fields['phase'] = 'completed'; fields['status'] = '502'
		fields['duration_ms'] = clock.elapsed().milliseconds().str()
		fields['error_class'] = 'database_transport_failed_no_replay'
		app.emit('relay.database.request', fields)
		return err
	}
	decoded := json.decode[dbx.Response](response) or { dbx.Response{} }
	fields['phase'] = 'completed'; fields['status'] = if decoded.ok { '200' } else { '502' }
	fields['duration_ms'] = clock.elapsed().milliseconds().str()
	if !decoded.ok { fields['error_class'] = 'database_operation_failed' }
	app.emit('relay.database.request', fields)
	return response
}

fn (mut app App) request_relay_database_once(relay_id string, route string, body string, timeout_ms int, binding relay.CarrierDispatchPlan, cancelled fn () bool, id string) !string {
	outcome := dispatch.relay_delivery_outcome_with_completion('relay:${relay_id}', {
		'frame_kind': 'open'
		'frame_id': id
		'channel_id': id
		'trace_id': id
		'request_id': id
		'route': route
		'body': body
	}, 'wait', timeout_ms)
	outbound := app.relay.prepare_outbound_delivery(outcome)
	if outbound.action != .ready { return error('relay_db_unavailable') }
	if !binding.is_current() { return error('relay_db_connection_changed') }
	if cancelled() { return error('relay_db_cancelled') }
	tracking := app.relay.track_outbound_delivery(outbound, 4)
	if tracking.action == .rejected { return error('relay_db_tracking_failed') }
	defer { app.relay.finish_outbound_delivery(outbound) }
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), outbound.carrier_id)
	sent := relay.send_to_carrier(mut carrier, outbound)
	if !sent.ok { return error('relay_db_send_failed') }
	clock := time.new_stopwatch()
	for clock.elapsed().milliseconds() < timeout_ms {
		if cancelled() { return error('relay_db_cancelled') }
		if !outbound.plan.is_current() { return error('relay_db_connection_changed') }
		completion := app.relay.response_completion_after_send(outbound, sent)
		if completion.action == .completed { return completion.delivery.body }
		if completion.action == .failed { return error('relay_db_remote_rejected') }
		time.sleep(time.millisecond)
	}
	return error('relay_db_timeout_result_unknown')
}

fn (mut app App) dispatch_relay_database(view PipelineDispatchView, adapter runtime_plan.AdapterPlan, exchange dispatch.Exchange) RelayPipelineDispatchOutcome {
	relay_id := exchange.metadata['relay_id']
	carrier_id := exchange.metadata['carrier_id']
	descriptor := view.plan.relays[relay_id] or { return relay_pipeline_failure(exchange, 403, 'relay_db_forbidden', 'relay_db_forbidden') }
	if descriptor.mode != 'hub' || descriptor.options.strings['token'] == '' || exchange.ingress != 'relay:${relay_id}' {
		return relay_pipeline_failure(exchange, 403, 'relay_db_forbidden', 'relay_db_forbidden')
	}
	binding := relay.carrier_dispatch_plan(app.relay.carriers, relay_id, relay.WireFrame{})
	if binding.carrier_id != carrier_id || !binding.is_current() { return relay_pipeline_failure(exchange, 403, 'relay_db_owner_closed', 'relay_db_owner_closed') }
	resource_id := adapter.options.strings['resource']
	resource := view.plan.resources[resource_id] or { return relay_pipeline_failure(exchange, 403, 'relay_db_resource_unavailable', 'relay_db_resource_unavailable') }
	access := adapter.options.strings['access']
	if resource.category != 'db' || resource.kind != 'mysql' || resource.options.strings['relay'] != '' || access !in ['', 'read-only', 'read-write'] {
		return relay_pipeline_failure(exchange, 403, 'relay_db_resource_unavailable', 'relay_db_resource_unavailable')
	}
	if relay_pipeline_exchange_body(exchange).len > 8388608 { return relay_pipeline_failure(exchange, 413, 'relay_db_request_limit', 'relay_db_request_limit') }
	envelope := json.decode[relaydb.Envelope](relay_pipeline_exchange_body(exchange)) or { return relay_pipeline_failure(exchange, 400, 'relay_db_invalid_message', 'relay_db_invalid_message') }
	if envelope.resource != resource_id { return relay_pipeline_failure(exchange, 403, 'relay_db_resource_forbidden', 'relay_db_resource_forbidden') }
	settings := db_runtime_settings_from_resource(resource)
	mut gateway := app.relay_databases
	response := gateway.run(carrier_id, envelope, settings, access != 'read-write', fn [binding] () bool { return !binding.is_current() }) or {
		// Do not reflect SQL, parameters, driver connection errors or credentials.
		return relay_pipeline_success_with_body(exchange, 'response', 200, json.encode(dbx.Response{driver: resource.kind, error: 'relay_db_operation_failed'}), map[string]string{})
	}
	return relay_pipeline_success_with_body(exchange, 'response', 200, response, map[string]string{})
}

fn (app &App) relay_frame_targets_database(relay_id string, carrier_id string, frame relay.WireFrame, at i64) bool {
	view := app.pipeline_dispatch_view()
	for exchange in view.relay.ingress_exchanges(relay_id, carrier_id, frame, at) {
		pipeline := view.plan.pipeline(exchange.pipeline) or { continue }
		if pipeline.egress.domain != .adapter { continue }
		adapter := view.plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind in ['db-resource', 'debug-http', 'debug-control'] { return true }
	}
	return false
}
