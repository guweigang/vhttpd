module browser_auth

import crypto.rand
import crypto.sha256
import sync

pub const browser_ticket_seconds = 30
pub const browser_session_seconds = 8 * 60 * 60

// Each Admin listener owns its own store. Restarting it invalidates all credentials.
@[heap]
pub struct BrowserAuth {
mut:
	mu       sync.Mutex
	tickets  map[string]i64
	sessions map[string]i64
}

fn (mut auth BrowserAuth) prune(now i64) {
	for key, expiry in auth.tickets { if expiry <= now { auth.tickets.delete(key) } }
	for key, expiry in auth.sessions { if expiry <= now { auth.sessions.delete(key) } }
}

pub fn (mut auth BrowserAuth) issue_ticket(now i64) !string {
	auth.mu.@lock()
	defer { auth.mu.unlock() }
	auth.prune(now)
	if auth.tickets.len >= 32 { return error('Too many pending browser logins') }
	ticket := rand.bytes(32)!.hex()
	auth.tickets[sha256.hexhash(ticket)] = now + browser_ticket_seconds
	return ticket
}

pub fn (mut auth BrowserAuth) exchange(ticket string, now i64) !string {
	auth.mu.@lock()
	defer { auth.mu.unlock() }
	auth.prune(now)
	key := sha256.hexhash(ticket)
	if ticket.len != 64 || key !in auth.tickets {
		return error('Login expired or already used. Open Admin UI from the workbench again.')
	}
	// Consume before issuing: concurrent redemptions cannot both succeed.
	auth.tickets.delete(key)
	if auth.sessions.len >= 64 { return error('Too many browser sessions') }
	session := rand.bytes(32)!.hex()
	auth.sessions[sha256.hexhash(session)] = now + browser_session_seconds
	return session
}

pub fn (mut auth BrowserAuth) authorized(session string, now i64) bool {
	if session.len != 64 { return false }
	auth.mu.@lock()
	defer { auth.mu.unlock() }
	auth.prune(now)
	return (auth.sessions[sha256.hexhash(session)] or { i64(0) }) > now
}

pub fn (mut auth BrowserAuth) revoke(session string) {
	auth.mu.@lock()
	defer { auth.mu.unlock() }
	auth.sessions.delete(sha256.hexhash(session))
}

// Cookie authentication must not authorize cross-origin browser requests.
// Ports matter here: another application on localhost is a different origin.
pub fn browser_request_allowed(method string, host string, origin string, fetch_site string, expected_origin string) bool {
	if 'http://${host}' != expected_origin { return false }
	if fetch_site != '' && fetch_site != 'same-origin' && fetch_site != 'none' { return false }
	if origin != '' && origin != expected_origin { return false }
	if method !in ['GET', 'HEAD', 'OPTIONS'] && origin != expected_origin { return false }
	return true
}
