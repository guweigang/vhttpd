module main

import admin
import crypto.rand
import dbx
import json2 as json
import relay
import relaydb
import upstream.transport
import veb

struct RelayDatabaseProbeInput {
	resource_id string
}

@['/admin/runtime/relay/database/probe'; post]
pub fn (mut app AdminApp) admin_relay_database_probe(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/relay/database/probe')
	if app.admin_token == '' || !admin.AdminAuth.authorized(app.admin_token, transport.header_map_from_request(ctx.req), {}) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	ctx.set_header(.cache_control, 'no-store')
	mut result := relaydb.ProbeResult{stage: 'input', error: 'invalid_probe_input'}
	if ctx.req.data.len <= 512 {
		if input := json.decode[map[string]json.Any](ctx.req.data) {
			if input.len == 1 && 'resource_id' in input {
				if value := json.decode[RelayDatabaseProbeInput](ctx.req.data) {
					result = app.shared.probe_relay_database(value.resource_id)
				}
			}
		}
	}
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(result), {})
}

fn (mut app App) probe_relay_database(resource_id string) relaydb.ProbeResult {
	if !resource_id.starts_with('db/') || resource_id.len > 128 {
		return relaydb.ProbeResult{stage: 'configuration', error: 'invalid_database_resource'}
	}
	view := app.pipeline_dispatch_view()
	resource := view.plan.resources[resource_id] or {
		return relaydb.ProbeResult{stage: 'configuration', error: 'unknown_database_resource'}
	}
	if resource.category != 'db' || resource.kind != 'mysql' || resource.options.strings['relay'] == '' {
		return relaydb.ProbeResult{stage: 'configuration', error: 'authenticated_mysql_relay_resource_required'}
	}
	relay_id := resource.options.strings['relay'].all_after('relay:')
	descriptor := view.plan.relays[relay_id] or {
		return relaydb.ProbeResult{stage: 'configuration', error: 'invalid_relay_database_binding'}
	}
	if descriptor.mode != 'agent' || descriptor.options.strings['token'] == '' || resource.options.strings['route'] == '' || !resource.options.strings['remote_resource'].starts_with('db/') {
		return relaydb.ProbeResult{stage: 'configuration', error: 'invalid_relay_database_binding'}
	}
	binding := relay.carrier_dispatch_plan(app.relay.carriers, relay_id, relay.WireFrame{})
	if !binding.is_current() { return relaydb.ProbeResult{stage: 'carrier', error: 'relay_not_connected'} }
	client_id := rand.bytes(16) or { return relaydb.ProbeResult{stage: 'response', error: 'invalid_database_response'} }
	route := resource.options.strings['route']
	envelope := relaydb.Envelope{client_id: client_id.hex(), resource: resource.options.strings['remote_resource'], request: dbx.Request{op: 'query', sql_text: relaydb.probe_sql, timeout_ms: 2500}}
	// Pin query and close to the same existing carrier generation. Inspect the
	// raw bounded reply so older peers' driver-less errors stay database errors.
	defer {
		app.request_relay_database(relay_id, route, json.encode(relaydb.Envelope{...envelope, request: dbx.Request{op: 'close', timeout_ms: 1000}}), 1000, binding, fn () bool { return false }) or {}
	}
	raw := app.request_relay_database(relay_id, route, json.encode(envelope), 2500, binding, fn () bool { return false }) or {
		return relaydb.ProbeResult{stage: 'transport', error: 'relay_database_transport_failed_no_replay'}
	}
	return relaydb.probe_response(raw)
}
