module host

import browser_auth
import crypto.sha256
import encoding.base64
import net.http
import net.urllib
import time
import sync

// Browser credentials belong to this loopback origin, never to the SSH tunnel.
@[heap]
struct RemoteProxy {
mut:
	mu     sync.Mutex
	active bool = true
	origin string
	target string
	token  string
	auth   &browser_auth.BrowserAuth = &browser_auth.BrowserAuth{}
}

fn proxy_response(code int, body string) http.Response {
	mut response := http.new_response(status: http.status_from_int(code), body: body)
	response.header.set(.cache_control, 'no-store')
	// Each V HTTP worker owns a connection until it closes. Browsers can open
	// more parallel connections than the proxy's bounded worker pool.
	response.header.set(.connection, 'close')
	// Preserve same-origin POST Origin headers while suppressing cross-origin referrers.
	response.header.set(.referrer_policy, 'same-origin')
	response.header.set(.content_type, 'application/json')
	return response
}

fn (mut p RemoteProxy) handle(req http.Request) http.Response {
	p.mu.@lock()
	active := p.active
	origin_url, target, token := p.origin, p.target, p.token
	mut auth := p.auth
	p.mu.unlock()
	if !active { return proxy_response(410, 'Connection closed') }
	path := req.url.all_before('?')
	request_host := req.header.get(.host) or { '' }
	origin := req.header.get(.origin) or { '' }
	if 'http://${request_host}' != origin_url { return proxy_response(403, 'Forbidden') }
	if path == '/admin/auth/exchange' && req.method == .post {
		if origin !in ['', 'null', origin_url] { return proxy_response(403, 'Forbidden') }
		form := urllib.parse_query(req.data) or { return proxy_response(400, 'Invalid ticket') }
		ticket := form.get('ticket') or { '' }
		if ticket.len != 64 || !ticket.bytes().all(it.is_hex_digit()) { return proxy_response(400, 'Invalid ticket') }
		// Commit a document on the proxy origin before setting a Strict cookie.
		// A file: POST followed directly by a 303 is still a cross-site chain in
		// real browsers, unlike an HTTP client manually replaying the cookie.
		script := 'document.forms[0].submit()'
		digest := sha256.sum(script.bytes())
		mut response := proxy_response(200, '<!doctype html><html><head><meta charset="utf-8"><meta name="referrer" content="same-origin"><title>正在登录远端 Admin</title></head><body><p>正在登录远端 Admin…</p><form method="post" action="/admin/auth/complete"><input type="hidden" name="ticket" value="${ticket}"><button type="submit">继续打开 Admin UI</button></form><script>${script}</script></body></html>')
		response.header.set(.content_type, 'text/html; charset=utf-8')
		response.header.set(.referrer_policy, 'same-origin')
		response.header.add_custom('Content-Security-Policy', "default-src 'none'; script-src 'sha256-${base64.encode(digest[..])}'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'") or {}
		return response
	}
	if path == '/admin/auth/complete' && req.method == .post {
		if !browser_auth.browser_request_allowed(req.method.str(), request_host, origin, req.header.get_custom('sec-fetch-site') or { '' }, origin_url) {
			return proxy_response(403, 'Forbidden')
		}
		form := urllib.parse_query(req.data) or { return proxy_response(400, 'Invalid ticket') }
		session := auth.exchange(form.get('ticket') or { '' }, time.now().unix()) or { return proxy_response(403, 'Login expired; open Admin UI from Desktop again.') }
		mut response := proxy_response(303, '')
		response.header.set(.location, '/admin/ui/')
		response.header.add(.set_cookie, http.Cookie{ name: 'vhttpd_remote', value: session, path: '/admin', http_only: true, same_site: .same_site_strict_mode }.str())
		return response
	}

	allowed := browser_auth.browser_request_allowed(req.method.str(), request_host, origin, req.header.get_custom('sec-fetch-site') or { '' }, origin_url)
	session := req.cookie('vhttpd_remote') or { http.Cookie{} }
	authorized := allowed && auth.authorized(session.value, time.now().unix())
	if path == '/admin/auth/session' && req.method == .get {
		return proxy_response(200, '{"authenticated":${authorized}}')
	}
	if !authorized { return proxy_response(403, 'Open Admin UI from Desktop to sign in.') }
	if path == '/admin/auth/logout' && req.method == .post {
		auth.revoke(session.value)
		return proxy_response(200, '{"authenticated":false}')
	}
	// No lifecycle control or host handoff may pass through browser credentials.
	if !path.starts_with('/admin/') || path.starts_with('/admin/auth/') || path.starts_with('/admin/workbench/') || path.contains('..') || path.contains('%') || path.contains('\\') {
		return proxy_response(403, 'Forbidden')
	}
	mut request := http.Request{ method: req.method, url: target + req.url, data: req.data, read_timeout: 15 * time.second, write_timeout: 15 * time.second, max_retries: 1, allow_redirect: false, disable_connection_reuse: true }
	request.add_custom_header('x-vhttpd-admin-token', token) or { return proxy_response(502, 'Connection unavailable') }
	if content_type := req.header.get(.content_type) {
		request.header.set(.content_type, content_type)
	}
	upstream := request.do() or { return proxy_response(502, 'SSH connection interrupted. Reconnect in Desktop.') }
	mut response := proxy_response(upstream.status_code, upstream.body)
	for key in [http.CommonHeader.content_type, .content_encoding, .content_disposition] {
		if value := upstream.header.get(key) { response.header.set(key, value) }
	}
	return response
}
