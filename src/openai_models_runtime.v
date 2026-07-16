module main

import api.openai
import json
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
	return OpenAIResponseWriter.write(mut app, mut ctx, 200, path, method, req_id, trace_id,
		start_ms, if method.to_upper() == 'HEAD' { '' } else { body },
		'application/json; charset=utf-8', map[string]string{}, map[string]string{})
}
