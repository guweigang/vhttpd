module main

import api.openai

fn (mut app App) openai_store_response_record(plan openai.OpenAIResolvedPlan, body string, req_id string, trace_id string) string {
	response_id := openai.OpenAIResponseRecord.id_from_body(body)
	if response_id == '' {
		return ''
	}
	record := openai.OpenAIResponseRecord.from_plan(plan, response_id, body, req_id, trace_id)
	app.protocols.openai.responses.set_with_ttl(response_id, record, openai_response_registry_ttl) or {}
	return response_id
}

fn (app &App) openai_models() []string {
	mut models := []string{}
	for name, route in app.protocols.openai.routes {
		for model in openai.OpenAIResolvedRoute.models(route, name) {
			if model !in models {
				models << model
			}
		}
	}
	models.sort()
	return models
}

fn (app &App) openai_resolve_route(model string) !openai.OpenAIResolvedRoute {
	requested := model.trim_space()
	if requested != '' {
		for name, route in app.protocols.openai.routes {
			if requested in openai.OpenAIResolvedRoute.models(route, name) {
				backend_name := if route.backend.trim_space() != '' {
					route.backend.trim_space()
				} else {
					app.protocols.openai.default_backend.trim_space()
				}
				if backend_name == '' {
					return error('missing backend for model ${requested}')
				}
				backend := app.protocols.openai.backends[backend_name] or {
					return error('unknown backend ${backend_name}')
				}
				upstream_model := if route.upstream_model.trim_space() != '' {
					route.upstream_model.trim_space()
				} else {
					requested
				}
				return openai.OpenAIResolvedRoute{
					route_name:     name
					model:          requested
					backend_name:   backend_name
					upstream_model: upstream_model
					backend:        backend
				}
			}
		}
	}
	backend_name := app.protocols.openai.default_backend.trim_space()
	if backend_name == '' {
		return error('no matching route for model ${requested}')
	}
	backend := app.protocols.openai.backends[backend_name] or {
		return error('unknown backend ${backend_name}')
	}
	return openai.OpenAIResolvedRoute{
		model:          requested
		backend_name:   backend_name
		upstream_model: requested
		backend:        backend
	}
}
