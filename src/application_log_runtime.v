module main

import application_catalog
import application_logs
import executor
import runtime_plan

// Reuse the same ownership rules as /admin/apps. A shared engine without one
// unambiguous application owner logs at environment scope rather than leaking
// output into every application that happens to share a listener/engine.
fn application_log_scopes(plan runtime_plan.RuntimePlan) map[string]application_logs.Scope {
	builder := application_catalog.Builder.new(plan)
	mut scopes := map[string]application_logs.Scope{}
	for pipeline in plan.pipelines {
		app_id := builder.app_id_from_pipeline(pipeline)
		listener := if pipeline.ingress.domain == .listener { pipeline.ingress.id } else { '' }
		engine := builder.pipeline_engine_ref(pipeline).all_after('engine:')
		scopes['pipeline:'+pipeline.id] = application_logs.Scope{app_id:app_id,engine_id:engine,listener_id:listener}
		if listener != '' {
			key := 'listener:'+listener
			if key !in scopes { scopes[key] = application_logs.Scope{app_id:app_id,listener_id:listener} }
			else if scopes[key].app_id != app_id { scopes[key] = application_logs.Scope{listener_id:listener} }
		}
		if engine != '' {
			key := 'engine:'+engine
			if key !in scopes { scopes[key] = application_logs.Scope{app_id:app_id,engine_id:engine} }
			else if scopes[key].app_id != app_id { scopes[key] = application_logs.Scope{engine_id:engine} }
		}
		for resource in builder.pipeline_resource_refs(builder.pipeline_engine_ref(pipeline),pipeline.egress) {
			if resource !in scopes { scopes[resource] = application_logs.Scope{app_id:app_id} }
			else if scopes[resource].app_id != app_id { scopes[resource] = application_logs.Scope{} }
		}
	}
	return scopes
}

fn (mut control ControlPlaneRuntime) record_application_relay_event(kind string, fields map[string]string) {
	pipeline := if fields['pipeline_id'] != '' { fields['pipeline_id'] } else if fields['pipeline'] != '' { fields['pipeline'] } else { fields['route'] }
	mut scope := control.application_log_scope(pipeline, fields['listener_id'])
	if pipeline == '' && fields['resource'] != '' {
		control.mu.@lock()
		scope = control.application_log_scopes['resource:'+fields['resource']] or { application_logs.Scope{} }
		control.mu.unlock()
	}
	mut logs := application_logs.shared()
	logs.append(scope,application_logs.Record{
		source:'relay'
		level:if fields['error_class'] != '' { 'error' } else { 'info' }
		message:kind+' '+fields['phase']+' '+fields['status']+' '+fields['operation']+' '+fields['error_class']
		request_id:fields['request_id']
		trace_id:fields['trace_id']
		pipeline_id:pipeline
	})
}

fn (mut runtime EngineRuntime) configure_application_logs(plan runtime_plan.RuntimePlan, listener_id string) {
	scopes := application_log_scopes(plan)
	if engine := plan.listener_fallback_engine(listener_id) {
		configure_executor_application_logs(runtime.primary.logic_executor, scopes['engine:'+engine.id] or { application_logs.Scope{engine_id:engine.id} })
	} else {
		configure_executor_application_logs(runtime.primary.logic_executor, scopes['listener:'+listener_id] or { application_logs.Scope{} })
	}
	for key,state in runtime.additional {
		engine := plan.engines[key] or { plan.listener_named_engine(listener_id,key) or { continue } }
		configure_executor_application_logs(state.logic_executor, scopes['engine:'+engine.id] or { application_logs.Scope{engine_id:engine.id} })
	}
}

fn configure_executor_application_logs(engine executor.LogicExecutor, scope application_logs.Scope) {
	if engine is executor.InProcVjsxExecutor { engine.set_application_log_scope(scope) }
}

fn (mut control ControlPlaneRuntime) configure_application_logs(plan runtime_plan.RuntimePlan) {
	scopes := application_log_scopes(plan)
	control.mu.@lock()
	control.application_log_scopes = scopes
	control.mu.unlock()
}

fn (mut control ControlPlaneRuntime) application_log_scope(pipeline string, listener string) application_logs.Scope {
	control.mu.@lock()
	defer { control.mu.unlock() }
	if pipeline != '' { return control.application_log_scopes['pipeline:'+pipeline] or { application_logs.Scope{} } }
	return control.application_log_scopes['listener:'+listener] or { application_logs.Scope{} }
}
