module relaydb

import crypto.sha256
import dbx
import json2 as json
import provider
import sync
import time

@[heap]
struct Entry {
	owner string
	signature string
	database &dbx.AsyncDatabase @[required]
}

// Only the authenticated carrier identity supplied by the server is an owner.
// Neither owner nor database settings are accepted from message payloads.
@[heap]
pub struct Gateway {
mut:
	mu sync.Mutex
	entries map[string]&Entry
	pools map[string]&dbx.PoolOwner
	started bool
	closed bool
	in_flight int
}

pub fn (mut g Gateway) run(owner string, e Envelope, settings provider.DbRuntimeSettings, read_only bool, cancelled fn () bool) !string {
	e.validate()!
	if owner == '' || !settings.enabled || settings.driver != 'mysql' { return error('relay_db_resource_unavailable') }
	key := owner + ':' + e.resource + ':' + e.client_id
	if e.request.op == 'close' {
		g.close_client(key)
		return json.encode(dbx.Response{ok: true, driver: settings.driver})
	}
	// Exports skip schema initialization, but retain the configured session
	// isolation required by cloud transactions. Read-only is applied last.
	access := provider.DbRuntimeSettings{...settings, init_sql: export_session_init_sql(settings.init_sql, read_only)}
	signature := sha256.hexhash(json.encode(access))
	g.mu.@lock()
	if g.closed || cancelled() { g.mu.unlock(); return error('relay_db_owner_closed') }
	if g.in_flight >= 64 { g.mu.unlock(); return error('relay_db_busy') }
	if !g.started { g.started = true; spawn g.sweep() }
	mut entry := g.entries[key] or {
		if g.entries.len >= 32 { g.mu.unlock(); return error('relay_db_client_limit') }
		mut pool := g.pools[signature] or {
			if g.pools.len >= 8 { g.mu.unlock(); return error('relay_db_resource_limit') }
			next := &dbx.PoolOwner{}
			g.pools[signature] = next
			next
		}
		next := &Entry{owner: owner, signature: signature, database: dbx.AsyncDatabase.new(dbx.AsyncDatabaseAccess{settings: access, owner: pool})}
		g.entries[key] = next
		next
	}
	g.in_flight++
	g.mu.unlock()
	defer {
		g.mu.@lock()
		g.in_flight--
		g.mu.unlock()
	}
	if entry.signature != signature { return error('relay_db_resource_changed') }
	return entry.database.run_json(json.encode(e.request), cancelled)!
}

fn export_session_init_sql(statements []string, read_only bool) []string {
	mut out := []string{}
	for statement in statements {
		normalized := statement.trim_space().trim_right(';').trim_space().fields().join(' ').to_upper()
		if normalized in [
			'SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED',
			'SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED',
			'SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ',
			'SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE',
		] {
			out << normalized
		}
	}
	if read_only { out << 'SET SESSION TRANSACTION READ ONLY' }
	return out
}

fn (mut g Gateway) close_client(key string) {
	g.mu.@lock()
	entry := g.entries[key] or { g.mu.unlock(); return }
	g.entries.delete(key)
	g.mu.unlock()
	entry.database.close()
}

pub fn (mut g Gateway) close_owner(owner string) {
	g.mu.@lock()
	mut keys := []string{}
	for key, entry in g.entries { if entry.owner == owner { keys << key } }
	g.mu.unlock()
	for key in keys { g.close_client(key) }
}

pub fn (mut g Gateway) close() {
	g.mu.@lock()
	g.closed = true
	keys := g.entries.keys()
	g.mu.unlock()
	for key in keys { g.close_client(key) }
	g.mu.@lock()
	mut pools := g.pools.values()
	g.pools.clear()
	g.mu.unlock()
	for mut pool in pools { pool.request_stop(); pool.close() }
}

fn (mut g Gateway) sweep() {
	for {
		time.sleep(100 * time.millisecond)
		g.mu.@lock()
		closed := g.closed
		entries := g.entries.values()
		g.mu.unlock()
		if closed { return }
		for entry in entries { entry.database.expire_transactions() }
	}
}
