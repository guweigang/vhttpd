module main

import browser_auth
import net.http
import time
import veb

fn (app AdminApp) browser_origin() string {
	host := if app.admin_host.contains(':') { '[${app.admin_host}]' } else { app.admin_host }
	return 'http://${host}:${app.admin_port}'
}

fn (app AdminApp) browser_cookie_name() string {
	return 'vhttpd_admin_${app.admin_port}'
}

fn (app AdminApp) browser_session_authorized(ctx Context) bool {
	if !browser_auth.browser_request_allowed(ctx.req.method.str(), ctx.req.header.get(.host) or { '' },
		ctx.req.header.get(.origin) or { '' }, ctx.req.header.get_custom('sec-fetch-site') or { '' }, app.browser_origin()) {
		return false
	}
	mut auth := app.browser_auth
	return auth.authorized(ctx.get_cookie(app.browser_cookie_name()) or { '' }, time.now().unix())
}

fn browser_auth_headers(mut ctx Context) {
	ctx.set_header(.cache_control, 'no-store')
	ctx.set_header(.pragma, 'no-cache')
	ctx.set_header(.referrer_policy, 'no-referrer')
}

// Only the authenticated native host can mint tickets. Credentials travel in
// headers/bodies, never query strings, redirects, event metadata or access URLs.
@['/admin/auth/handoff'; post]
pub fn (mut app AdminApp) browser_handoff(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	if app.admin_host !in ['127.0.0.1', 'localhost', '::1'] || app.admin_token == ''
		|| ctx.req.header.get(.origin) or { '' } != ''
		|| ctx.req.header.get_custom('x-vhttpd-admin-token') or { '' } != app.admin_token {
		ctx.res.set_status(.forbidden)
		return ctx.text('Forbidden')
	}
	mut auth := app.browser_auth
	ticket := auth.issue_ticket(time.now().unix()) or {
		ctx.res.set_status(.too_many_requests)
		return ctx.text('Too many pending browser logins')
	}
	return ctx.json({
		'ticket': ticket
	})
}

@['/admin/auth/exchange'; post]
pub fn (mut app AdminApp) browser_exchange(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	origin := ctx.req.header.get(.origin) or { '' }
	if 'http://${ctx.req.header.get(.host) or { '' }}' != app.browser_origin()
		|| (origin != '' && origin != 'null' && origin != app.browser_origin()) {
		ctx.res.set_status(.forbidden)
		return ctx.text('Forbidden')
	}
	mut auth := app.browser_auth
	session := auth.exchange(ctx.form['ticket'], time.now().unix()) or {
		ctx.res.set_status(.forbidden)
		return ctx.text('Login expired or already used. Open Admin UI from the workbench again.')
	}
	ctx.set_cookie(http.Cookie{
		name:      app.browser_cookie_name()
		value:     session
		path:      '/admin'
		http_only: true
		same_site: .same_site_strict_mode
	})
	return ctx.redirect('/admin/ui/', typ: .see_other)
}

@['/admin/auth/session'; get]
pub fn (mut app AdminApp) browser_session(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	return ctx.json({
		'authenticated': app.browser_session_authorized(ctx)
	})
}

@['/admin/auth/logout'; post]
pub fn (mut app AdminApp) browser_logout(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	if !app.browser_session_authorized(ctx) {
		ctx.res.set_status(.forbidden)
		return ctx.text('Forbidden')
	}
	mut auth := app.browser_auth
	auth.revoke(ctx.get_cookie(app.browser_cookie_name()) or { '' })
	ctx.set_cookie(http.Cookie{
		name:      app.browser_cookie_name()
		path:      '/admin'
		max_age:   -1
		http_only: true
		same_site: .same_site_strict_mode
	})
	return ctx.json({
		'authenticated': false
	})
}
