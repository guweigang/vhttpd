module relaydb

import dbx
import json2 as json

fn test_database_protocol_rejects_unknown_operations_versions_and_unbounded_requests() ! {
	base := Envelope{client_id: '0123456789abcdef0123456789abcdef', resource: 'db/test', request: dbx.Request{op: 'query', timeout_ms: 1000}}
	base.validate()!
	// The cloud SDK gives transactions a cleanup allowance beyond the query
	// timeout; its default BEGIN budget exceeds 30 seconds.
	Envelope{...base, request: dbx.Request{op: 'begin', timeout_ms: 38000}}.validate()!
	for bad in [Envelope{...base, version: 2}, Envelope{...base, client_id: ''}, Envelope{...base, resource: 'secret/key'}, Envelope{...base, request: dbx.Request{op: 'schema', timeout_ms: 1000}}, Envelope{...base, request: dbx.Request{op: 'query', timeout_ms: 300001}}] {
		bad.validate() or { continue }
		assert false, 'invalid resource envelope accepted'
	}
}

fn test_transport_failure_retires_client_and_closes_peer_without_retrying_sql() ! {
	mut calls := &ProtocolCalls{}
	mut c := Client.new('db/test', fn [mut calls] (body string, _ int, _ fn () bool) !string {
		e := json.decode[Envelope](body)!
		calls.ops << e.request.op
		if e.request.op == 'close' { return json.encode(dbx.Response{ok: true, driver: 'mysql'}) }
		return error('response_lost')
	})!
	c.run_json('{"op":"execute","sql":"INSERT INTO t VALUES (?)","params":["a"]}', fn () bool { return false }) or {
		assert err.msg() == 'response_lost'
	}
	c.run_json('{"op":"query","sql":"SELECT 1"}', fn () bool { return false }) or {
		assert err.msg() == 'relay_db_client_closed'
	}
	c.close()
	assert calls.ops == ['execute', 'close']
}

@[heap]
struct ProtocolCalls {
mut:
	ops []string
}
