module main

import api.openai
import time
import upstream.transport
import veb

fn OpenAIProxyRuntime.executor_once(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	resp := app.openai_call_executor(plan, method, path, req_id, trace_id) or {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'openai_executor_failed', err.msg())
	}
	body := openai.OpenAIResponseBuilder.executor_once_body(plan, resp.result, req_id,
		int(time.now().unix()))
	ctx.res.set_status(.ok)
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-vhttpd-openai-backend', plan.backend_name) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
		'executor':    plan.backend.executor
	})
	return ctx.text(if method.to_upper() == 'HEAD' { '' } else { body })
}
