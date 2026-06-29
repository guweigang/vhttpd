module main

import crypto.sha256
import dispatch
import executor
import json
import net.http
import os
import rand
import veb

struct UploadPayload {
	filename     string
	content_type string
	body         string
}

struct UploadResponse {
	ok           bool
	event        string
	upload_id    string @[json: 'upload_id']
	filename     string
	mime_type    string @[json: 'mime_type']
	size         int
	sha256       string
	path         string
	on_completed string @[json: 'on_completed']
	handler      string
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

fn upload_completed_spec_from_handler(handler string) string {
	clean := handler.trim_space()
	if clean == '' {
		return ''
	}
	return 'vjsx:${clean}'
}

fn upload_completed_dispatch_status(outcome executor.HttpLogicDispatchOutcome) int {
	if outcome.kind == .response {
		return outcome.response.status
	}
	if outcome.kind == .stream {
		return outcome.stream_start.status
	}
	return 0
}

struct UploadCompletedTransformDispatchResult {
	attempted bool
	ok        bool
}

fn upload_completed_dispatch_fields(resp UploadResponse, route string, handler string, status string) map[string]string {
	mut out := map[string]string{}
	out['upload_id'] = resp.upload_id.clone()
	out['filename'] = resp.filename.clone()
	out['mime_type'] = resp.mime_type.clone()
	out['size'] = '${resp.size}'
	out['sha256'] = resp.sha256.clone()
	out['path'] = resp.path.clone()
	out['route'] = route.clone()
	out['on_completed'] = upload_completed_spec_from_handler(handler)
	out['handler'] = handler.clone()
	out['request_id'] = resp.request_id.clone()
	out['trace_id'] = resp.trace_id.clone()
	if status != '' {
		out['dispatch_status'] = status
	}
	return out
}

fn upload_completed_exchange_for_pipeline(resp UploadResponse, fields map[string]string, ingress_ref string, pipeline_id string) dispatch.Exchange {
	ingress := if ingress_ref.trim_space() == '' {
		'adapter:upload'
	} else {
		ingress_ref.trim_space()
	}
	pipeline := if pipeline_id.trim_space() == '' {
		'upload.completed'
	} else {
		pipeline_id.trim_space()
	}
	return dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         resp.upload_id
			request_id: resp.request_id
			trace_id:   resp.trace_id
		}
		kind:     .event
		ingress:  ingress
		pipeline: pipeline
		headers:  map[string]string{}
		metadata: fields.clone()
		payload:  dispatch.EventPayload{
			topic:    'upload'
			name:     'upload.completed'
			data:     json.encode(resp)
			metadata: fields.clone()
		}
	}
}

fn (mut app App) dispatch_upload_completed_transforms(rule RuntimeRouteRule, handler string, resp UploadResponse, fields map[string]string) UploadCompletedTransformDispatchResult {
	transform_refs := rule.upload_completed_transform_refs
	if transform_refs.len == 0 {
		return UploadCompletedTransformDispatchResult{}
	}
	route := fields['route'] or { '' }
	mut services := noop_dispatch_services(resp.trace_id)
	mut exchange := upload_completed_exchange_for_pipeline(resp, fields,
		rule.upload_completed_ingress_ref, rule.upload_completed_pipeline_id)
	result := app.run_transform_refs(transform_refs, mut services, mut exchange) or {
		mut failed := upload_completed_dispatch_fields(resp, route, handler, '')
		failed['error'] = err.msg()
		failed['transforms'] = transform_refs.join(',')
		app.emit('upload.completed.transform_failed', failed)
		return UploadCompletedTransformDispatchResult{
			attempted: true
		}
	}
	mut ok := upload_completed_dispatch_fields(resp, route, handler, if result.halted {
		'halted'
	} else {
		'transform'
	})
	ok['transforms'] = transform_refs.join(',')
	if result.transform != '' {
		ok['transform'] = result.transform
	}
	app.emit('upload.completed.dispatch', ok)
	return UploadCompletedTransformDispatchResult{
		attempted: true
		ok:        true
	}
}

fn (mut app App) dispatch_upload_completed_vjsx(handler string, resp UploadResponse, fields map[string]string) {
	clean_handler := handler.trim_space().clone()
	if clean_handler == '' {
		return
	}
	route := fields['route'] or { '' }
	outcome := app.dispatch_vjsx_event(VjsxEventDispatchRequest{
		event:      'upload.completed'
		handler:    clean_handler
		payload:    vjsx_event_payload(resp)
		trace_id:   resp.trace_id
		request_id: resp.request_id
	}) or {
		mut failed := upload_completed_dispatch_fields(resp, route, clean_handler, '')
		failed['error'] = err.msg()
		if err.msg() == 'vjsx_executor_unavailable' {
			failed['reason'] = err.msg()
			app.emit('upload.completed.dispatch_skipped', failed)
			return
		}
		app.emit('upload.completed.dispatch_failed', failed)
		return
	}
	ok := upload_completed_dispatch_fields(resp, route, clean_handler,
		'${upload_completed_dispatch_status(outcome)}')
	app.emit('upload.completed.dispatch', ok)
}

fn handle_upload_route(mut app App, mut ctx Context, rule RuntimeRouteRule, method string, path string, req_id string, trace_id string, start_ms i64, query map[string]string, body_on_head string, remote_addr string) veb.Result {
	if method.to_upper() != 'POST' && method.to_upper() != 'PUT' {
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/upload_method',
			405, map[string]string{}, 'Method Not Allowed'))
		return render_http_terminal_adapter(mut app, mut ctx, method, path, path, query,
			body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut terminal_adapter)
	}
	if ctx.req.data.len == 0 {
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/upload_empty',
			400, map[string]string{}, 'empty upload body'))
		return render_http_terminal_adapter(mut app, mut ctx, method, path, path, query,
			body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut terminal_adapter)
	}
	upload_dir := if rule.upload_dir.trim_space() != '' {
		rule.upload_dir
	} else {
		os.join_path(os.temp_dir(), 'vhttpd-uploads')
	}
	os.mkdir_all(upload_dir) or {
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/upload_dir',
			500, map[string]string{}, 'upload dir unavailable'))
		return render_http_terminal_adapter(mut app, mut ctx, method, path, path, query,
			body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut terminal_adapter)
	}
	payload := upload_payload_from_request(ctx.req)
	filename := sanitize_upload_filename(payload.filename)
	upload_id := 'upl_' + rand.uuid_v4().replace('-', '')
	stored_name := upload_id + '_' + filename
	path_out := os.join_path(upload_dir, stored_name)
	os.write_file(path_out, payload.body) or {
		mut terminal_adapter := dispatch.EgressAdapter(dispatch.fixed_response_adapter('route/upload_write',
			500, map[string]string{}, 'upload write failed'))
		return render_http_terminal_adapter(mut app, mut ctx, method, path, path, query,
			body_on_head, remote_addr, req_id, trace_id, start_ms, rule, mut terminal_adapter)
	}
	sum := sha256.sum(payload.body.bytes()).hex().to_lower()
	on_completed := rule.on_completed.trim_space().clone()
	handler := upload_completed_vjsx_handler(on_completed).clone()
	resp := UploadResponse{
		ok:           true
		event:        'upload.completed'
		upload_id:    upload_id
		filename:     filename
		mime_type:    payload.content_type
		size:         payload.body.len
		sha256:       sum
		path:         path_out
		on_completed: on_completed
		handler:      handler
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
		'handler':      handler
		'request_id':   req_id
		'trace_id':     trace_id
	}
	app.emit('upload.completed', fields)
	transform_dispatch := app.dispatch_upload_completed_transforms(rule, handler, resp, fields)
	if !transform_dispatch.attempted {
		app.dispatch_upload_completed_vjsx(handler, resp, fields)
	}
	mut headers := {
		'content-type':       'application/json; charset=utf-8'
		'x-vhttpd-upload-id': upload_id
	}
	if rule.cache_control.trim_space() != '' {
		headers['cache-control'] = rule.cache_control
	}
	outcome := dispatch.response_outcome(201, headers, json.encode(resp))
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, body_on_head, remote_addr, req_id, trace_id, start_ms), outcome, rule)
}
