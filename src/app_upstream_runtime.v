module main

import dispatch
import upstream.transport
import veb

fn (mut app App) build_upstream_runtime_context() UpstreamRuntimeContext {
	mut control := &app.control_plane
	return app.upstreams.build_context(fn [mut control] (kind string, fields map[string]string) {
		control.emit(kind, fields)
	},
		fn [mut app] (mut ctx Context, req HttpIngressRequest, error_class string) veb.Result {
			return UpstreamRuntimeContext.render_validation_failure(mut app, mut ctx, req, error_class)
		})
}

fn UpstreamRuntimeContext.render_validation_failure(mut app App, mut ctx Context, req HttpIngressRequest, error_class string) veb.Result {
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, req, dispatch.outcome_with_metadata(dispatch.response_outcome(502, {
		'content-type':          'text/plain; charset=utf-8'
		'x-vhttpd-error-class':  error_class
		'x-vhttpd-stream-mode':  'upstream_plan'
		'x-vhttpd-stream-stage': 'validate'
	}, 'Bad Gateway'), {
		'error_class':  error_class
		'stream_mode':  'upstream_plan'
		'stream_stage': 'validate'
	}), none)
}

fn (mut app App) upstream_runtime_register(plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) ?UpstreamRuntimeRegistration {
	runtime := app.build_upstream_runtime_context()
	return runtime.register(plan, method, path, req_id, trace_id)
}

fn (mut app App) upstream_runtime_unregister(registration UpstreamRuntimeRegistration) {
	runtime := app.build_upstream_runtime_context()
	runtime.unregister(registration)
}

fn (mut app App) upstream_runtime_note_error() {
	runtime := app.build_upstream_runtime_context()
	runtime.note_error()
}

fn (mut app App) admin_upstreams_snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	runtime := app.build_upstream_runtime_context()
	return runtime.snapshot(details, limit, offset, role_filter, provider_filter)
}
