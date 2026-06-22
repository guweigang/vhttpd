module main

import api.openai
import json
import time
import upstream.transport
import veb

fn (mut app App) openai_handle_models(mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['GET', 'HEAD'] {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 405, path, method, req_id,
			trace_id, start_ms, 'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	models := if app.protocols.openai.plugin.trim_space() != '' {
		result := app.openai_plugin_models(method, path, req_id, trace_id) or {
			return OpenAIErrorResponseWriter.write(mut app, mut ctx, 500, path, method, req_id,
				trace_id, start_ms, 'plugin_error', err.msg())
		}
		if result.handled {
			result.models
		} else {
			app.openai_models()
		}
	} else {
		app.openai_models()
	}
	mut data := []openai.OpenAIModelObject{}
	for model in models {
		data << openai.OpenAIModelObject{
			id:      model
			created: int(app.lifecycle.started_at_unix)
		}
	}
	body := json.encode(openai.OpenAIModelsResponse{
		data: data
	})
	ctx.res.set_status(.ok)
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
	})
	return ctx.text(if method.to_upper() == 'HEAD' { '' } else { body })
}
