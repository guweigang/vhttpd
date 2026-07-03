module main

import dispatch
import relay
import runtime_plan
import ws

struct RelayPipelineDispatchOutcome {
	pipeline_id         string
	exchange_id         string
	trace_id            string
	channel_id          string
	action              string
	status              int
	body                string
	headers             map[string]string
	error               string
	error_class         string
	carrier_id          string
	response_frame_id   string
	carrier_send_ok     bool
	carrier_send_queued bool
	carrier_send_error  string
}

fn relay_pipeline_dispatch_event_fields(outcome RelayPipelineDispatchOutcome) map[string]string {
	return {
		'pipeline_id':         outcome.pipeline_id
		'exchange_id':         outcome.exchange_id
		'trace_id':            outcome.trace_id
		'channel_id':          outcome.channel_id
		'action':              outcome.action
		'status':              outcome.status.str()
		'error':               outcome.error
		'error_class':         outcome.error_class
		'carrier_id':          outcome.carrier_id
		'response_frame_id':   outcome.response_frame_id
		'carrier_send_ok':     outcome.carrier_send_ok.str()
		'carrier_send_queued': outcome.carrier_send_queued.str()
		'carrier_send_error':  outcome.carrier_send_error
	}
}

fn relay_pipeline_response_frame(outcome RelayPipelineDispatchOutcome) relay.WireFrame {
	return relay.WireFrame{
		version:       relay.wire_version
		kind:          if outcome.action == 'failed' {
			relay.WireFrameKind.error
		} else {
			relay.WireFrameKind.data
		}
		id:            'relay-response:${outcome.exchange_id}'
		trace_id:      outcome.trace_id
		channel_id:    outcome.channel_id
		exchange_kind: if outcome.action == 'failed' { 'error' } else { 'response' }
		metadata:      {
			'pipeline_id': outcome.pipeline_id
			'action':      outcome.action
			'status':      outcome.status.str()
			'error_class': outcome.error_class
			'response_to': outcome.exchange_id
		}
		headers:       outcome.headers.clone()
		body:          if outcome.body != '' { outcome.body } else { outcome.error }
	}
}

fn relay_frame_should_dispatch_pipeline(frame relay.WireFrame) bool {
	if relay.frame_is_pipeline_response(frame) {
		return false
	}
	return frame.kind in [.open, .data, .end, .cancel]
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

fn (mut app App) dispatch_and_send_relay_ingress_frame(relay_id string, carrier_id string, frame relay.WireFrame, created_at_ms i64) []RelayPipelineDispatchOutcome {
	mut outcomes := app.dispatch_relay_ingress_frame(relay_id, carrier_id, frame, created_at_ms)
	mut carrier := ws.new_relay_carrier(app.build_websocket_runtime_context(), carrier_id)
	for i, outcome in outcomes {
		response_frame := relay_pipeline_response_frame(outcome)
		send_result := carrier.send(response_frame)
		outcomes[i] = relay_pipeline_outcome_with_send_result(outcome, carrier_id,
			response_frame.id, send_result)
		mut fields := relay_pipeline_dispatch_event_fields(outcomes[i])
		for key, value in relay.carrier_send_event_fields(send_result) {
			fields['carrier_${key}'] = value
		}
		app.emit('relay.pipeline.response', fields)
	}
	return outcomes
}

fn relay_pipeline_outcome_with_send_result(outcome RelayPipelineDispatchOutcome, carrier_id string, response_frame_id string, send_result relay.CarrierSendResult) RelayPipelineDispatchOutcome {
	return RelayPipelineDispatchOutcome{
		...outcome
		carrier_id:          carrier_id
		response_frame_id:   response_frame_id
		carrier_send_ok:     send_result.ok
		carrier_send_queued: send_result.queued
		carrier_send_error:  send_result.error
	}
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
	if pipeline.egress.domain == .adapter {
		return app.dispatch_relay_pipeline_adapter_egress(pipeline.egress.id, mut services,
			exchange)
	}
	return relay_pipeline_terminal_outcome(exchange, pipeline.egress.str())
}

fn (mut app App) dispatch_relay_pipeline_adapter_egress(adapter_id string, mut services dispatch.RuntimeServices, exchange dispatch.Exchange) RelayPipelineDispatchOutcome {
	adapter_plan := app.plan.adapters[adapter_id] or {
		return relay_pipeline_failure(exchange, 404, 'relay_adapter_unknown:${adapter_id}',
			'relay_adapter_unknown')
	}
	if adapter_plan.kind == 'provider-action' {
		return app.dispatch_relay_provider_action_adapter(adapter_plan, adapter_id, exchange)
	}
	mut adapter := dispatch.terminal_adapter_from_plan(adapter_plan) or {
		return relay_pipeline_failure(exchange, 501,
			'relay_pipeline_egress_unsupported:adapter:${adapter_id}',
			'relay_pipeline_egress_unsupported')
	}
	delivery := adapter.deliver(mut services, exchange) or {
		return relay_pipeline_failure(exchange, 500, err.msg(), 'relay_adapter_failed')
	}
	return relay_pipeline_outcome_from_delivery(exchange, delivery)
}

fn (mut app App) dispatch_relay_provider_action_adapter(adapter_plan runtime_plan.AdapterPlan, adapter_id string, exchange dispatch.Exchange) RelayPipelineDispatchOutcome {
	payload := provider_action_payload(adapter_plan, relay_pipeline_exchange_body(exchange))
	resp := app.dispatch_provider_action_adapter(adapter_plan, adapter_id, payload,
		exchange.identity.request_id, exchange.identity.trace_id, {
		'pipeline_id': exchange.pipeline
		'ingress':     exchange.ingress
		'exchange_id': exchange.identity.id
		'channel_id':  exchange.metadata['channel_id'] or { '' }
	})
	if !resp.ok {
		return relay_pipeline_failure(exchange, 500, resp.error, 'relay_provider_action_failed')
	}
	return relay_pipeline_success_with_body(exchange, 'response',
		provider_action_response_status(adapter_plan), resp.result, {
		'content-type': provider_action_response_content_type(adapter_plan)
	})
}

fn relay_pipeline_terminal_outcome(exchange dispatch.Exchange, egress string) RelayPipelineDispatchOutcome {
	match egress {
		'terminal:ack' {
			return relay_pipeline_outcome_from_delivery(exchange, dispatch.accepted_event_outcome({
				'action': 'accepted'
			}))
		}
		'terminal:response' {
			return relay_pipeline_outcome_from_delivery(exchange, dispatch.response_outcome(200,
				map[string]string{}, relay_pipeline_exchange_body(exchange)))
		}
		'terminal:reject' {
			return relay_pipeline_outcome_from_delivery(exchange, dispatch.delivery_failure_outcome(403,
				'rejected', 'relay_terminal_reject'))
		}
		else {
			return relay_pipeline_failure(exchange, 501,
				'relay_pipeline_egress_unsupported:${egress}', 'relay_pipeline_egress_unsupported')
		}
	}
}

fn relay_pipeline_outcome_from_delivery(exchange dispatch.Exchange, delivery dispatch.DeliveryOutcome) RelayPipelineDispatchOutcome {
	match delivery.kind {
		.response {
			return relay_pipeline_success_with_body(exchange, 'response', if delivery.status > 0 {
				delivery.status
			} else {
				200
			}, delivery.body, delivery.headers)
		}
		.accepted_event {
			return relay_pipeline_success_with_body(exchange, 'accepted', if delivery.status > 0 {
				delivery.status
			} else {
				202
			}, delivery.metadata['body'] or { '' }, map[string]string{})
		}
		.failure {
			return relay_pipeline_failure(exchange, if delivery.status > 0 {
				delivery.status
			} else {
				500
			}, delivery.error, delivery.error_class)
		}
		else {
			return relay_pipeline_failure(exchange, 501,
				'relay_delivery_kind_unsupported:${delivery.kind}',
				'relay_delivery_kind_unsupported')
		}
	}
}

fn relay_pipeline_exchange_body(exchange dispatch.Exchange) string {
	match exchange.payload {
		dispatch.RequestPayload { return exchange.payload.body }
		dispatch.ResponsePayload { return exchange.payload.body }
		dispatch.EventPayload { return exchange.payload.data }
		dispatch.StreamPayload { return exchange.payload.chunk }
		dispatch.SessionPayload { return exchange.payload.message }
		dispatch.ErrorPayload { return exchange.payload.message }
		dispatch.EmptyPayload { return '' }
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
	return relay_pipeline_success_with_body(exchange, action, status, action, map[string]string{})
}

fn relay_pipeline_success_with_body(exchange dispatch.Exchange, action string, status int, body string, headers map[string]string) RelayPipelineDispatchOutcome {
	return RelayPipelineDispatchOutcome{
		pipeline_id: exchange.pipeline
		exchange_id: exchange.identity.id
		trace_id:    exchange.identity.trace_id
		channel_id:  exchange.metadata['channel_id'] or { '' }
		action:      action
		status:      status
		body:        body
		headers:     headers.clone()
	}
}

fn relay_pipeline_failure(exchange dispatch.Exchange, status int, error string, error_class string) RelayPipelineDispatchOutcome {
	return RelayPipelineDispatchOutcome{
		pipeline_id: exchange.pipeline
		exchange_id: exchange.identity.id
		trace_id:    exchange.identity.trace_id
		channel_id:  exchange.metadata['channel_id'] or { '' }
		action:      'failed'
		status:      status
		body:        error
		error:       error
		error_class: error_class
	}
}
