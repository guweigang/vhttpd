module main

import admin
import json2 as json
import log
import upstream.transport
import veb

struct TlsCertificateReloadRequest {
	listener string
}

@['/admin/runtime/tls/reload'; post]
pub fn (mut app AdminApp) admin_reload_tls_certificate(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/tls/reload')
	// Require explicit token authentication for the local runtime mutation.
	if app.admin_token == ''
		|| !admin.AdminAuth.authorized(app.admin_token, transport.header_map_from_request(ctx.req), {}) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	body := ctx.req.data.trim_space()
	request := if body == '' {
		TlsCertificateReloadRequest{}
	} else {
		json.decode[TlsCertificateReloadRequest](body) or {
			return admin_tls_reload_error(mut app, mut ctx, req, 400, 'invalid_tls_reload_request')
		}
	}
	mut runtime := app.shared.lifecycle.tls_certificates
	listener := runtime.listener(request.listener.trim_space()) or {
		return admin_tls_reload_error(mut app, mut ctx, req, err.code(), err.msg())
	}
	listener.reload() or {
		log.warn('[vhttpd] TLS certificate reload failed for ${listener.address}: ${err.msg()}')
		return admin_tls_reload_error(mut app, mut ctx, req, 422, 'tls_certificate_reload_failed')
	}
	app.shared.emit('admin.tls.reload', {
		'listener':   listener.address
		'request_id': req.req_id
	})
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode({
		'status':   'reloaded'
		'listener': listener.address
	}), {})
}

fn admin_tls_reload_error(mut app AdminApp, mut ctx Context, req AdminPlaneRequest, status int, code string) veb.Result {
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(admin.AdminErrorResponse{
		error: code
	}), {
		'error': code
	})
}
