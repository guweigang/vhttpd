module main

import crypto.sha256
import executor
import json
import net.http
import os
import rand
import time
import upstream.transport
import veb

struct UploadPayload {
	filename     string
	content_type string
	body         string
}

struct UploadResponse {
	ok           bool
	upload_id    string @[json: 'upload_id']
	filename     string
	mime_type    string @[json: 'mime_type']
	size         int
	sha256       string
	path         string
	on_completed string @[json: 'on_completed']
	trace_id     string @[json: 'trace_id']
	request_id   string @[json: 'request_id']
}

fn sanitize_upload_filename(name string) string {
	clean := os.file_name(name).trim_space()
	if clean == '' || clean == '.' || clean == '..' {
		return 'upload.bin'
	}
	mut out := []u8{cap: clean.len}
	for ch in clean.bytes() {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
			|| (ch >= `0` && ch <= `9`) || ch in [`_`, `-`, `.`, `+`] {
			out << ch
		} else {
			out << `_`
		}
	}
	result := out.bytestr().trim('.')
	return if result == '' { 'upload.bin' } else { result }
}

fn header_param_value(header string, key string) string {
	prefix := key + '='
	for part in header.split(';') {
		clean := part.trim_space()
		if clean.starts_with(prefix) {
			mut value := clean[prefix.len..].trim_space()
			if value.len >= 2 && value[0] == `"` && value[value.len - 1] == `"` {
				value = value[1..value.len - 1]
			}
			return value
		}
	}
	return ''
}

fn multipart_boundary(content_type string) string {
	for part in content_type.split(';') {
		clean := part.trim_space()
		if clean.starts_with('boundary=') {
			mut value := clean['boundary='.len..].trim_space()
			if value.len >= 2 && value[0] == `"` && value[value.len - 1] == `"` {
				value = value[1..value.len - 1]
			}
			return value
		}
	}
	return ''
}

fn parse_multipart_upload(body string, content_type string) ?UploadPayload {
	boundary := multipart_boundary(content_type)
	if boundary == '' {
		return none
	}
	marker := '--' + boundary
	for raw_part in body.split(marker) {
		mut part := raw_part
		if part.starts_with('--') || part.trim_space() == '' {
			continue
		}
		part = part.trim_left('\r\n')
		sep := '\r\n\r\n'
		idx := part.index(sep) or { continue }
		headers_text := part[..idx]
		mut content := part[idx + sep.len..]
		if content.ends_with('\r\n') {
			content = content[..content.len - 2]
		}
		mut filename := ''
		mut part_content_type := 'application/octet-stream'
		for line in headers_text.split('\r\n') {
			lower := line.to_lower()
			if lower.starts_with('content-disposition:') {
				filename = header_param_value(line.all_after(':'), 'filename')
			} else if lower.starts_with('content-type:') {
				part_content_type = line.all_after(':').trim_space()
			}
		}
		if filename != '' {
			return UploadPayload{
				filename:     filename
				content_type: part_content_type
				body:         content
			}
		}
	}
	return none
}

fn upload_payload_from_request(req http.Request) UploadPayload {
	content_type := req.header.get(.content_type) or { '' }
	if payload := parse_multipart_upload(req.data, content_type) {
		return payload
	}
	filename_header := req.header.get_custom('x-vhttpd-filename') or { 'upload.bin' }
	return UploadPayload{
		filename:     filename_header
		content_type: if content_type != '' { content_type } else { 'application/octet-stream' }
		body:         req.data
	}
}

fn upload_completed_vjsx_handler(on_completed string) string {
	clean := on_completed.trim_space()
	if !clean.starts_with('vjsx:') {
		return ''
	}
	return clean['vjsx:'.len..].trim_space()
}

fn upload_completed_event_path(handler string) string {
	clean := handler.trim_space().trim_left('/')
	if clean == '' {
		return '/__vhttpd/events/upload.completed'
	}
	return '/__vhttpd/events/upload.completed/${clean}'
}

fn (mut app App) dispatch_upload_completed_vjsx(handler string, resp UploadResponse, fields map[string]string) {
	if handler.trim_space() == '' {
		return
	}
	body := json.encode(resp)
	mut req := http.Request{
		method: .post
		url:    upload_completed_event_path(handler)
		data:   body
		host:   'vhttpd.internal'
	}
	req.header.set(.content_type, 'application/json; charset=utf-8')
	req.header.set_custom('x-vhttpd-event', 'upload.completed') or {}
	req.header.set_custom('x-vhttpd-upload-id', resp.upload_id) or {}
	req.header.set_custom('x-vhttpd-trace-id', resp.trace_id) or {}
	req.header.set_custom('x-request-id', resp.request_id) or {}
	mut facade := app.as_facade()
	if app.logic_executor_kind() == 'vjsx' {
		_ := app.executors.worker.logic_executor.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{
			method:        'POST'
			path:          req.url
			original_path: req.url
			req:           req
			remote_addr:   '127.0.0.1'
			trace_id:      resp.trace_id
			request_id:    resp.request_id
		}) or {
			mut failed := fields.clone()
			failed['handler'] = handler
			failed['error'] = err.msg()
			app.emit('upload.completed.dispatch_failed', failed)
			return
		}
		mut ok := fields.clone()
		ok['handler'] = handler
		app.emit('upload.completed.dispatch', ok)
		return
	}
	if state := app.additional_workers['vjsx'] {
		_ := state.logic_executor.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{
			method:        'POST'
			path:          req.url
			original_path: req.url
			req:           req
			remote_addr:   '127.0.0.1'
			trace_id:      resp.trace_id
			request_id:    resp.request_id
		}) or {
			mut failed := fields.clone()
			failed['handler'] = handler
			failed['error'] = err.msg()
			app.emit('upload.completed.dispatch_failed', failed)
			return
		}
		mut ok := fields.clone()
		ok['handler'] = handler
		app.emit('upload.completed.dispatch', ok)
		return
	}
	mut skipped := fields.clone()
	skipped['handler'] = handler
	skipped['reason'] = 'vjsx_executor_unavailable'
	app.emit('upload.completed.dispatch_skipped', skipped)
}

fn handle_upload_route(mut app App, mut ctx Context, rule RuntimeRouteRule, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() != 'POST' && method.to_upper() != 'PUT' {
		ctx.res.set_status(.method_not_allowed)
		return ctx.text('Method Not Allowed')
	}
	if ctx.req.data.len == 0 {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(.bad_request)
		return ctx.text('empty upload body')
	}
	upload_dir := if rule.upload_dir.trim_space() != '' {
		rule.upload_dir
	} else {
		os.join_path(os.temp_dir(), 'vhttpd-uploads')
	}
	os.mkdir_all(upload_dir) or {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(.internal_server_error)
		return ctx.text('upload dir unavailable')
	}
	payload := upload_payload_from_request(ctx.req)
	filename := sanitize_upload_filename(payload.filename)
	upload_id := 'upl_' + rand.uuid_v4().replace('-', '')
	stored_name := upload_id + '_' + filename
	path_out := os.join_path(upload_dir, stored_name)
	os.write_file(path_out, payload.body) or {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(.internal_server_error)
		return ctx.text('upload write failed')
	}
	sum := sha256.sum(payload.body.bytes()).hex().to_lower()
	resp := UploadResponse{
		ok:           true
		upload_id:    upload_id
		filename:     filename
		mime_type:    payload.content_type
		size:         payload.body.len
		sha256:       sum
		path:         path_out
		on_completed: rule.on_completed
		trace_id:     trace_id
		request_id:   req_id
	}
	fields := {
		'upload_id':    resp.upload_id
		'filename':     resp.filename
		'mime_type':    resp.mime_type
		'size':         '${resp.size}'
		'sha256':       resp.sha256
		'path':         resp.path
		'route':        path
		'on_completed': resp.on_completed
		'request_id':   req_id
		'trace_id':     trace_id
	}
	app.emit('upload.completed', fields)
	app.dispatch_upload_completed_vjsx(upload_completed_vjsx_handler(rule.on_completed), resp,
		fields)
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.normalize_path(path)
		'status':      '201'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-vhttpd-upload-id', upload_id) or {}
	if rule.cache_control.trim_space() != '' {
		ctx.set_custom_header('cache-control', rule.cache_control) or {}
	}
	apply_route_response_headers(mut ctx, rule)
	ctx.res.set_status(http.status_from_int(201))
	ctx.set_content_type('application/json; charset=utf-8')
	return ctx.text(json.encode(resp))
}
