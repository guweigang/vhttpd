module main

import json
import net.unix
import os

struct InternalAdminRequest {
	mode   string
	method string
	path   string
	query  map[string]string
	body   string
}

struct InternalAdminResponse {
	status  int
	headers map[string]string
	body    string
	error   string
}

fn default_internal_admin_socket() string {
	return '/tmp/vhttpd_admin_${os.getpid()}.sock'
}

fn internal_admin_normalize_path(raw string) string {
	mut path := normalize_path(raw)
	if path == '/admin' {
		return '/'
	}
	if path.starts_with('/admin/') {
		path = path.all_after('/admin')
		if path == '' {
			return '/'
		}
	}
	return path
}

fn internal_gateway_normalize_path(raw string) string {
	mut path := normalize_path(raw)
	if path == '/gateway' {
		return '/'
	}
	if path.starts_with('/gateway/') {
		path = path.all_after('/gateway')
		if path == '' {
			return '/'
		}
	}
	return path
}

fn internal_admin_json_response(body string) InternalAdminResponse {
	return InternalAdminResponse{
		status:  200
		headers: {
			'content-type': 'application/json; charset=utf-8'
		}
		body:    body
	}
}

fn internal_admin_error_response(status int, message string) InternalAdminResponse {
	return InternalAdminResponse{
		status:  status
		headers: {
			'content-type': 'application/json; charset=utf-8'
		}
		body:    json.encode({
			'error': message
		})
		error:   message
	}
}

fn internal_gateway_bad_request(errmsg string) InternalAdminResponse {
	return internal_admin_error_response(400, errmsg)
}

fn (mut app App) internal_admin_dispatch(req InternalAdminRequest) InternalAdminResponse {
	if req.mode != 'vhttpd_admin' {
		return internal_admin_error_response(400, 'invalid_mode')
	}
	if req.method.trim_space().to_upper() != 'GET' {
		return internal_admin_error_response(405, 'method_not_allowed')
	}
	path := internal_admin_normalize_path(req.path)
	match path {
		'/executors' {
			return internal_admin_json_response(json.encode(app.admin_logic_executor_specs_snapshot()))
		}
		'/runtime' {
			return internal_admin_json_response(json.encode(app.admin_runtime_snapshot()))
		}
		'/runtime/feishu' {
			return internal_admin_json_response(app.provider_runtime_snapshot('feishu') or { '{}' })
		}
		'/runtime/feishu/chats' {
			limit := admin_query_limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin_query_offset(req.query['offset'] or { '' })
			instance := (req.query['instance'] or { '' }).trim_space()
			chat_type := (req.query['chat_type'] or { '' }).trim_space()
			chat_id := (req.query['chat_id'] or { '' }).trim_space()
			return internal_admin_json_response(json.encode(app.feishu_runtime_chats_snapshot(limit,
				offset, instance, chat_type, chat_id)))
		}
		'/runtime/upstreams/websocket' {
			details := admin_query_boolish(req.query['details'] or { 'false' })
			limit := admin_query_limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin_query_offset(req.query['offset'] or { '' })
			provider := (req.query['provider'] or { '' }).trim_space()
			instance := (req.query['instance'] or { '' }).trim_space()
			return internal_admin_json_response(json.encode(app.admin_websocket_upstreams_snapshot(details,
				limit, offset, provider, instance)))
		}
		'/runtime/upstreams/websocket/events' {
			limit := admin_query_limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin_query_offset(req.query['offset'] or { '' })
			provider := (req.query['provider'] or { '' }).trim_space()
			instance := (req.query['instance'] or { '' }).trim_space()
			return internal_admin_json_response(json.encode(app.admin_websocket_upstream_events_snapshot(limit,
				offset, provider, instance)))
		}
		'/runtime/upstreams/websocket/activities' {
			limit := admin_query_limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin_query_offset(req.query['offset'] or { '' })
			provider := (req.query['provider'] or { '' }).trim_space()
			instance := (req.query['instance'] or { '' }).trim_space()
			return internal_admin_json_response(json.encode(app.admin_websocket_upstream_activities_snapshot(limit,
				offset, provider, instance)))
		}
		else {
			return internal_admin_error_response(404, 'not_found')
		}
	}
}

fn internal_gateway_upload_request_from_body(body string) !FeishuRuntimeUploadImageRequest {
	return json.decode(FeishuRuntimeUploadImageRequest, body)
}

fn (mut app App) internal_gateway_dispatch(req InternalAdminRequest, binary_payload []u8) InternalAdminResponse {
	if req.mode != 'vhttpd_gateway' {
		return internal_admin_error_response(400, 'invalid_mode')
	}
	if req.method.trim_space().to_upper() != 'POST' {
		return internal_admin_error_response(405, 'method_not_allowed')
	}
	path := internal_gateway_normalize_path(req.path)
	match path {
		'/upstreams/websocket/send', '/feishu/messages' {
			send_req := json.decode(WebSocketUpstreamSendRequest, req.body) or {
				return internal_gateway_bad_request('invalid_json')
			}
			result := app.websocket_upstream_send(send_req) or {
				return InternalAdminResponse{
					status:  502
					headers: {
						'content-type': 'application/json; charset=utf-8'
					}
					body:    json.encode({
						'error': err.msg()
					})
					error:   err.msg()
				}
			}
			return internal_admin_json_response(json.encode(result))
		}
		'/feishu/images' {
			upload_req := internal_gateway_upload_request_from_body(req.body) or {
				return internal_gateway_bad_request('invalid_json')
			}
			mut result := FeishuRuntimeUploadImageResult{}
			if binary_payload.len > 0 {
				result = app.feishu_runtime_upload_image_bytes(upload_req, binary_payload) or {
					return InternalAdminResponse{
						status:  502
						headers: {
							'content-type': 'application/json; charset=utf-8'
						}
						body:    json.encode({
							'error': err.msg()
						})
						error:   err.msg()
					}
				}
			} else {
				result = app.feishu_runtime_upload_image(upload_req) or {
					return InternalAdminResponse{
						status:  502
						headers: {
							'content-type': 'application/json; charset=utf-8'
						}
						body:    json.encode({
							'error': err.msg()
						})
						error:   err.msg()
					}
				}
			}
			return internal_admin_json_response(json.encode(result))
		}
		else {
			return internal_admin_error_response(404, 'not_found')
		}
	}
}

fn run_internal_admin_server(mut app App, socket_path string) {
	if socket_path.trim_space() == '' {
		return
	}
	os.mkdir_all(os.dir(socket_path)) or {}
	mut listener := unix.listen_stream(socket_path) or {
		app.emit('internal_admin.error', {
			'socket': socket_path
			'error':  err.msg()
		})
		return
	}
	defer {
		listener.close() or {}
	}
	app.emit('internal_admin.started', {
		'socket': socket_path
	})
	for {
		mut conn := listener.accept() or {
			app.emit('internal_admin.error', {
				'socket': socket_path
				'error':  err.msg()
			})
			continue
		}
		payload := read_frame(mut conn) or {
			conn.close() or {}
			continue
		}
		req := json.decode(InternalAdminRequest, payload) or {
			app.emit('internal_admin.invalid_json', {
				'socket':          socket_path
				'payload_len':     '${payload.len}'
				'payload_preview': if payload.len > 256 { payload[..256] } else { payload }
			})
			write_frame(mut conn, json.encode(internal_admin_error_response(400, 'invalid_json'))) or {}
			conn.close() or {}
			continue
		}
		mut binary_payload := []u8{}
		if req.mode == 'vhttpd_gateway'
			&& internal_gateway_normalize_path(req.path) == '/feishu/images' {
			upload_req := internal_gateway_upload_request_from_body(req.body) or {
				write_frame(mut conn, json.encode(internal_admin_error_response(400, 'invalid_json'))) or {}
				conn.close() or {}
				continue
			}
			if upload_req.content_length > 0 {
				binary_payload = read_frame_bytes(mut conn) or {
					write_frame(mut conn, json.encode(internal_admin_error_response(400,
						'missing_binary_payload'))) or {}
					conn.close() or {}
					continue
				}
				if binary_payload.len != upload_req.content_length {
					write_frame(mut conn, json.encode(internal_admin_error_response(400,
						'invalid_binary_payload_length'))) or {}
					conn.close() or {}
					continue
				}
			}
		}
		resp := if req.mode == 'vhttpd_gateway' {
			app.internal_gateway_dispatch(req, binary_payload)
		} else {
			app.internal_admin_dispatch(req)
		}
		write_frame(mut conn, json.encode(resp)) or {}
		conn.close() or {}
	}
}
