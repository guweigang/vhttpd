module relaydb

import crypto.rand
import dbx
import json2 as json
import sync

pub const protocol_version = 1

pub struct Envelope {
pub:
	version int = protocol_version
	client_id string
	resource string
	request dbx.Request
}

pub fn (e Envelope) validate() ! {
	if e.version != protocol_version { return error('relay_db_protocol_version') }
	if e.client_id.len != 32 || !e.client_id.bytes().all(it.is_hex_digit()) { return error('relay_db_invalid_client') }
	if !e.resource.starts_with('db/') || e.resource.len > 128 { return error('relay_db_invalid_resource') }
	if e.request.op !in ['query', 'execute', 'begin', 'commit', 'rollback', 'close'] { return error('relay_db_invalid_operation') }
	if e.request.timeout_ms < 1 || e.request.timeout_ms > 300000 { return error('relay_db_invalid_timeout') }
	if e.request.sql_text.len > 4194304 || e.request.params.len > 1000 || e.request.params_base64.len > 1000 { return error('relay_db_request_limit') }
}

pub type Send = fn (string, int, fn () bool) !string

@[heap]
struct CallbackConnection {
	send_fn Send @[required]
}

fn (connection CallbackConnection) send(body string, timeout int, cancelled fn () bool) !string {
	return connection.send_fn(body, timeout, cancelled)
}

fn (_ CallbackConnection) is_current() bool { return true }

// One transport generation owns a capability. Failures retire this generation;
// RecoveringClient admits later requests through a fresh capability.
@[heap]
pub struct Client {
	id string
	resource string
	connection Connection @[required]
mut:
	mu sync.Mutex
	closed bool
}

pub fn Client.new(resource string, send Send) !&Client {
	return new_client(resource, &CallbackConnection{send_fn: send})
}

fn new_client(resource string, connection Connection) !&Client {
	return &Client{id: rand.bytes(16)!.hex(), resource: resource, connection: connection}
}

pub fn (mut c Client) run_json(raw string, cancelled fn () bool) !string {
	mut req := json.decode[dbx.Request](raw)!
	if req.timeout_ms == 0 { req = dbx.Request{...req, timeout_ms: 30000} }
	if req.session_id != '' {
		prefix := c.id + ':'
		if !req.session_id.starts_with(prefix) || req.session_id.len == prefix.len {
			return error('relay_db_transaction_connection_lost')
		}
		req = dbx.Request{...req, session_id: req.session_id[prefix.len..]}
	}
	e := Envelope{client_id: c.id, resource: c.resource, request: req}
	e.validate()!
	c.mu.@lock()
	closed := c.closed
	c.mu.unlock()
	if closed { return error('relay_db_client_closed') }
	if cancelled() { return error('relay_db_cancelled') }
	response := c.connection.send(json.encode(e), req.timeout_ms, cancelled) or {
		// A failed BEGIN can have reached the peer. Retire all its leases.
		c.close()
		return err
	}
	decoded := json.decode[dbx.Response](response) or {
		c.close()
		return error('relay_db_invalid_response')
	}
	if decoded.driver !in ['mysql', 'pgsql'] {
		c.close()
		return error('relay_db_invalid_driver')
	}
	if req.op in ['begin', 'commit', 'rollback'] && !decoded.ok {
		// A failed BEGIN must reject before the JS transaction callback runs;
		// otherwise an empty session could turn its writes into autocommit SQL.
		return error('relay_db_transaction_failed')
	}
	if req.op == 'begin' && decoded.ok && decoded.session_id == '' {
		c.close()
		return error('relay_db_invalid_transaction_response')
	}
	// Remote session counters can restart at 1 after a reconnect. The local
	// handle includes this capability's identity, so old handles never alias it.
	if decoded.session_id != '' {
		return json.encode(dbx.Response{...decoded, session_id: c.id + ':' + decoded.session_id})
	}
	return response
}

fn (mut c Client) is_closed() bool {
	c.mu.@lock()
	defer { c.mu.unlock() }
	return c.closed
}

pub fn (mut c Client) close() {
	c.mu.@lock()
	if c.closed { c.mu.unlock(); return }
	c.closed = true
	c.mu.unlock()
	c.connection.send(json.encode(Envelope{client_id: c.id, resource: c.resource, request: dbx.Request{op: 'close', timeout_ms: 1000}}), 1000, fn () bool { return false }) or {}
}
