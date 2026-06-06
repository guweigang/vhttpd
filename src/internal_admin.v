module main

import admin
import json
import net.unix
import os
import worker

type InternalAdminRequest = admin.InternalAdminRequest
type InternalAdminResponse = admin.InternalAdminResponse

fn (mut app App) internal_admin_dispatch(req InternalAdminRequest) InternalAdminResponse {
	if req.mode != 'vhttpd_admin' {
		return InternalAdminResponse.error(400, 'invalid_mode')
	}
	if req.method.trim_space().to_upper() != 'GET' {
		return InternalAdminResponse.error(405, 'method_not_allowed')
	}
	path := InternalAdminRequest.normalize_admin_path(req.path)
	match path {
		'/executors' {
			return InternalAdminResponse.json(json.encode(app.admin_logic_executor_specs_snapshot()))
		}
		'/runtime' {
			return InternalAdminResponse.json(json.encode(app.admin_runtime_snapshot()))
		}
		'/runtime/provider-instances' {
			provider := (req.query['provider'] or { '' }).trim_space()
			return InternalAdminResponse.json(json.encode(app.admin_provider_instance_snapshots(provider)))
		}
		'/runtime/feishu' {
			return InternalAdminResponse.json(app.provider_runtime_snapshot('feishu') or { '{}' })
		}
		'/runtime/db' {
			return InternalAdminResponse.json(app.provider_runtime_snapshot('db') or { '{}' })
		}
		'/runtime/feishu/chats' {
			limit := admin.AdminQuery.limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin.AdminQuery.offset(req.query['offset'] or { '' })
			instance := (req.query['instance'] or { '' }).trim_space()
			chat_type := (req.query['chat_type'] or { '' }).trim_space()
			chat_id := (req.query['chat_id'] or { '' }).trim_space()
			return InternalAdminResponse.json(json.encode(app.feishu_runtime_chats_snapshot(limit,
				offset, instance, chat_type, chat_id)))
		}
		'/runtime/upstreams/websocket' {
			details := admin.AdminQuery.parse_boolish(req.query['details'] or { 'false' })
			limit := admin.AdminQuery.limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin.AdminQuery.offset(req.query['offset'] or { '' })
			provider := (req.query['provider'] or { '' }).trim_space()
			instance := (req.query['instance'] or { '' }).trim_space()
			return InternalAdminResponse.json(json.encode(app.admin_websocket_upstreams_snapshot(details,
				limit, offset, provider, instance)))
		}
		'/runtime/upstreams/websocket/events' {
			limit := admin.AdminQuery.limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin.AdminQuery.offset(req.query['offset'] or { '' })
			provider := (req.query['provider'] or { '' }).trim_space()
			instance := (req.query['instance'] or { '' }).trim_space()
			return InternalAdminResponse.json(json.encode(app.admin_websocket_upstream_events_snapshot(limit,
				offset, provider, instance)))
		}
		'/runtime/upstreams/websocket/activities' {
			limit := admin.AdminQuery.limit(req.query['limit'] or { '' }, 100, 1000)
			offset := admin.AdminQuery.offset(req.query['offset'] or { '' })
			provider := (req.query['provider'] or { '' }).trim_space()
			instance := (req.query['instance'] or { '' }).trim_space()
			return InternalAdminResponse.json(json.encode(app.admin_websocket_upstream_activities_snapshot(limit,
				offset, provider, instance)))
		}
		else {
			return InternalAdminResponse.error(404, 'not_found')
		}
	}
}

fn (mut app App) internal_gateway_dispatch(req InternalAdminRequest, binary_payload []u8) InternalAdminResponse {
	if req.mode != 'vhttpd_gateway' {
		return InternalAdminResponse.error(400, 'invalid_mode')
	}
	if req.method.trim_space().to_upper() != 'POST' {
		return InternalAdminResponse.error(405, 'method_not_allowed')
	}
	path := InternalAdminRequest.normalize_gateway_path(req.path)
	match path {
		'/upstreams/websocket/send', '/feishu/messages' {
			send_req := json.decode(WebSocketUpstreamSendRequest, req.body) or {
				return InternalAdminResponse.bad_request('invalid_json')
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
			return InternalAdminResponse.json(json.encode(result))
		}
		'/feishu/images' {
			upload_req := FeishuRuntimeUploadImageRequest.from_json(req.body) or {
				return InternalAdminResponse.bad_request('invalid_json')
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
			return InternalAdminResponse.json(json.encode(result))
		}
		else {
			return InternalAdminResponse.error(404, 'not_found')
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
		payload := worker.WorkerBackendFrameCodec.read(mut conn) or {
			conn.close() or {}
			continue
		}
		req := json.decode(InternalAdminRequest, payload) or {
			app.emit('internal_admin.invalid_json', {
				'socket':          socket_path
				'payload_len':     '${payload.len}'
				'payload_preview': if payload.len > 256 { payload[..256] } else { payload }
			})
			worker.WorkerBackendFrameCodec.write(mut conn, json.encode(InternalAdminResponse.error(400,
				'invalid_json'))) or {}
			conn.close() or {}
			continue
		}
		mut binary_payload := []u8{}
		if req.mode == 'vhttpd_gateway'
			&& InternalAdminRequest.normalize_gateway_path(req.path) == '/feishu/images' {
			upload_req := FeishuRuntimeUploadImageRequest.from_json(req.body) or {
				worker.WorkerBackendFrameCodec.write(mut conn, json.encode(InternalAdminResponse.error(400,
					'invalid_json'))) or {}
				conn.close() or {}
				continue
			}
			if upload_req.content_length > 0 {
				binary_payload = worker.WorkerBackendFrameCodec.read_bytes(mut conn) or {
					worker.WorkerBackendFrameCodec.write(mut conn, json.encode(InternalAdminResponse.error(400,
						'missing_binary_payload'))) or {}
					conn.close() or {}
					continue
				}
				if binary_payload.len != upload_req.content_length {
					worker.WorkerBackendFrameCodec.write(mut conn, json.encode(InternalAdminResponse.error(400,
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
		worker.WorkerBackendFrameCodec.write(mut conn, json.encode(resp)) or {}
		conn.close() or {}
	}
}
