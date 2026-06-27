module main

import dispatch
import relay

struct RelayPipelineDispatchOutcome {
	pipeline_id string
	exchange_id string
	trace_id    string
	action      string
	status      int
	error       string
	error_class string
}

fn relay_pipeline_dispatch_event_fields(outcome RelayPipelineDispatchOutcome) map[string]string {
	return {
		'pipeline_id': outcome.pipeline_id
		'exchange_id': outcome.exchange_id
		'trace_id':    outcome.trace_id
		'action':      outcome.action
		'status':      outcome.status.str()
		'error':       outcome.error
		'error_class': outcome.error_class
	}
}

struct AppDispatchServices {
mut:
	app   &App = unsafe { nil }
	trace string
}

fn (services AppDispatchServices) trace_id() string {
	return services.trace
}

fn (services AppDispatchServices) emit(event string, fields map[string]string) {
	if isnil(services.app) {
		return
	}
	unsafe {
		mut app := services.app
		app.emit(event, fields)
	}
}

fn (mut app App) dispatch_relay_ingress_frame(relay_id string, carrier_id string, frame relay.WireFrame, created_at_ms i64) []RelayPipelineDispatchOutcome {
	exchanges := app.pipelines.relay.ingress_exchanges(relay_id, carrier_id, frame, created_at_ms)
	if exchanges.len == 0 {
		return [
			RelayPipelineDispatchOutcome{
				trace_id:    frame.trace_id
				exchange_id: frame.id
				action:      'rejected'
				status:      404
				error:       'relay_pipeline_not_found:${relay_id}'
				error_class: 'relay_pipeline_not_found'
			},
		]
	}
	mut outcomes := []RelayPipelineDispatchOutcome{cap: exchanges.len}
	for item in exchanges {
		mut exchange := item
		outcomes << app.dispatch_relay_pipeline_exchange(mut exchange)
	}
	return outcomes
}

fn (mut app App) dispatch_relay_pipeline_exchange(mut exchange dispatch.Exchange) RelayPipelineDispatchOutcome {
	pipeline := app.plan.pipeline(exchange.pipeline) or {
		return relay_pipeline_failure(exchange, 404, 'relay_pipeline_unknown:${exchange.pipeline}',
			'relay_pipeline_unknown')
	}
	mut services := dispatch.RuntimeServices(AppDispatchServices{
		app:   unsafe { &app }
		trace: exchange.identity.trace_id
	})
	transform_result := app.run_transform_refs(pipeline.transforms.map(it.str()), mut services, mut
		exchange) or {
		return relay_pipeline_failure(exchange, 500, err.msg(), 'relay_transform_failed')
	}
	if transform_result.halted {
		return relay_pipeline_transform_action(exchange, transform_result)
	}
	return relay_pipeline_terminal_outcome(exchange, pipeline.egress.str())
}

fn relay_pipeline_terminal_outcome(exchange dispatch.Exchange, egress string) RelayPipelineDispatchOutcome {
	match egress {
		'terminal:ack' {
			return relay_pipeline_success(exchange, 'accepted', 202)
		}
		'terminal:response' {
			return relay_pipeline_success(exchange, 'response', 200)
		}
		'terminal:reject' {
			return relay_pipeline_failure(exchange, 403, 'rejected', 'relay_terminal_reject')
		}
		else {
			return relay_pipeline_failure(exchange, 501,
				'relay_pipeline_egress_unsupported:${egress}', 'relay_pipeline_egress_unsupported')
		}
	}
}

fn relay_pipeline_transform_action(exchange dispatch.Exchange, result TransformPipelineResult) RelayPipelineDispatchOutcome {
	action := result.action
	match action.kind {
		.respond {
			return relay_pipeline_success(exchange, 'response', if action.status > 0 {
				action.status
			} else {
				200
			})
		}
		.reject {
			return relay_pipeline_failure(exchange, if action.status > 0 {
				action.status
			} else {
				403
			}, action.error, if action.error_class != '' {
				action.error_class
			} else {
				'relay_transform_rejected'
			})
		}
		.drop {
			return relay_pipeline_success(exchange, 'dropped', 204)
		}
		else {
			return relay_pipeline_failure(exchange, 501,
				'relay_transform_action_unsupported:${action.kind}',
				'relay_transform_action_unsupported')
		}
	}
}

fn relay_pipeline_success(exchange dispatch.Exchange, action string, status int) RelayPipelineDispatchOutcome {
	return RelayPipelineDispatchOutcome{
		pipeline_id: exchange.pipeline
		exchange_id: exchange.identity.id
		trace_id:    exchange.identity.trace_id
		action:      action
		status:      status
	}
}

fn relay_pipeline_failure(exchange dispatch.Exchange, status int, error string, error_class string) RelayPipelineDispatchOutcome {
	return RelayPipelineDispatchOutcome{
		pipeline_id: exchange.pipeline
		exchange_id: exchange.identity.id
		trace_id:    exchange.identity.trace_id
		action:      'failed'
		status:      status
		error:       error
		error_class: error_class
	}
}
