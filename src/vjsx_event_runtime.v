module main

import executor
import json2 as json
import net.http

struct VjsxEventDispatchRequest {
	event       string
	handler     string
	executor    string
	payload     string
	trace_id    string
	request_id  string
	remote_addr string = '127.0.0.1'
}

fn vjsx_event_path(event string, handler string) string {
	clean_event := event.trim_space().trim('/')
	clean_handler := handler.trim_space().trim_left('/')
	if clean_event == '' {
		return ''
	}
	if clean_handler == '' {
		return '/__vhttpd/events/${clean_event}'
	}
	return '/__vhttpd/events/${clean_event}/${clean_handler}'
}

fn vjsx_event_payload[T](payload T) string {
	return json.encode(payload, escape_unicode: true, time_as_unix: true)
}

fn (mut app App) dispatch_vjsx_event(req VjsxEventDispatchRequest) !executor.HttpLogicDispatchOutcome {
	return app.dispatch_vjsx_event_on_runtime(req, app.engine_runtime_snapshot())!
}

fn (mut app App) dispatch_vjsx_event_on_runtime(req VjsxEventDispatchRequest, retained EngineRuntime) !executor.HttpLogicDispatchOutcome {
	handler := req.handler.trim_space().clone()
	event := req.event.trim_space().clone()
	path := vjsx_event_path(event, handler)
	if event == '' {
		return error('vjsx_event_missing_event')
	}
	if handler == '' {
		return error('vjsx_event_missing_handler')
	}
	if path == '' {
		return error('vjsx_event_missing_path')
	}
	mut http_req := http.Request{
		method: .post
		url:    path
		data:   req.payload
		host:   'vhttpd.internal'
	}
	http_req.header.set(.content_type, 'application/json; charset=utf-8')
	http_req.header.set_custom('x-vhttpd-event', event) or {}
	http_req.header.set_custom('x-vhttpd-trace-id', req.trace_id) or {}
	http_req.header.set_custom('x-request-id', req.request_id) or {}
	mut facade := app.as_facade()
	dispatch_req := executor.HttpLogicDispatchRequest{
		method:        'POST'
		path:          path
		original_path: path
		req:           http_req
		remote_addr:   if req.remote_addr.trim_space() == '' {
			'127.0.0.1'
		} else {
			req.remote_addr
		}
		trace_id:      req.trace_id
		request_id:    req.request_id
	}
	mut engines := retained
	return engines.dispatch_http_for_kind(engines.vjsx_event_dispatch_executor(req.executor), mut
		facade, dispatch_req)!
}

fn (mut app App) vjsx_event_dispatch_executor(executor_name string) string {
	engines := app.engine_runtime_snapshot()
	return engines.vjsx_event_dispatch_executor(executor_name)
}

fn (engines &EngineRuntime) vjsx_event_dispatch_executor(executor_name string) string {
	clean := executor_name.trim_space()
	if clean != '' && clean in engines.additional {
		return clean
	}
	return 'vjsx'
}
