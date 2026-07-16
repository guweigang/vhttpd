module main

import api.openai
import time
import veb

fn OpenAIProxyRuntime.executor_once(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	resp := app.openai_call_executor(plan, method, path, req_id, trace_id) or {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'openai_executor_failed', err.msg())
	}
	body := openai.OpenAIResponseBuilder.executor_once_body(plan, resp.result, req_id,
		int(time.now().unix()))
	return OpenAIResponseWriter.write(mut app, mut ctx, 200, path, method, req_id, trace_id,
		start_ms, if method.to_upper() == 'HEAD' { '' } else { body },
		'application/json; charset=utf-8', {
		'x-vhttpd-openai-backend': plan.backend_name
	}, {
		'backend':  plan.backend_name
		'executor': plan.backend.executor
	})
}
