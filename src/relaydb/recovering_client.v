module relaydb

import dbx
import json2 as json
import sync

// Concrete transports hold attachment state explicitly. Factories run inside
// short-lived worker callback scopes, so returned objects must not contain
// newly captured function pointers whose scope ends with that request.
pub interface Connection {
	send(string, int, fn () bool) !string
	is_current() bool
}

pub type Connect = fn () !Connection

@[heap]
struct ClientGeneration {
	client &Client @[required]
	connection Connection
}

// Recovery only admits NEW operations. An operation that was sent once is
// never retried, including BEGIN/COMMIT when its result is unknown.
@[heap]
pub struct RecoveringClient {
	resource string
	connect Connect @[required]
mut:
	mu sync.Mutex
	generation ?&ClientGeneration
	closed bool
}

pub fn RecoveringClient.new(resource string, connect Connect) &RecoveringClient {
	return &RecoveringClient{resource: resource, connect: connect}
}

fn (mut c RecoveringClient) acquire(transaction bool) !&ClientGeneration {
	c.mu.@lock()
	if c.closed { c.mu.unlock(); return error('relay_db_client_closed') }
	previous := c.generation
	if current := previous {
		if !current.client.is_closed() && current.connection.is_current() {
			c.mu.unlock()
			return current
		}
	}
	if transaction {
		c.mu.unlock()
		if current := previous { current.client.close() }
		return error('relay_db_transaction_connection_lost')
	}
	connection := c.connect() or { c.mu.unlock(); return err }
	client := new_client(c.resource, connection) or { c.mu.unlock(); return err }
	next := &ClientGeneration{client: client, connection: connection}
	c.generation = next
	c.mu.unlock()
	if current := previous { current.client.close() }
	return next
}

pub fn (mut c RecoveringClient) run_json(raw string, cancelled fn () bool) !string {
	req := json.decode[dbx.Request](raw)!
	if cancelled() { return error('relay_db_cancelled') }
	current := c.acquire(req.session_id != '')!
	response := current.client.run_json(raw, cancelled)!
	c.mu.@lock()
	active := if generation := c.generation { voidptr(generation) == voidptr(current) } else { false }
	valid := !c.closed && active && !current.client.is_closed() && current.connection.is_current()
	c.mu.unlock()
	if !valid {
		current.client.close()
		return error('relay_db_connection_changed')
	}
	return response
}

pub fn (mut c RecoveringClient) close() {
	c.mu.@lock()
	c.closed = true
	current := c.generation
	c.generation = none
	c.mu.unlock()
	if generation := current { generation.client.close() }
}
