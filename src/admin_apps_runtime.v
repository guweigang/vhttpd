module main

import runtime_plan

struct AdminAppSummary {
pub mut:
	id             string
	label          string
	kind           string
	status         string
	listeners      []AdminAppListenerSummary
	engines        []AdminAppRuntimeItem
	adapters       []AdminAppRuntimeItem
	pipelines      []AdminAppPipelineFlow
	resources      []AdminAppRuntimeItem
	providers      []AdminAppRuntimeItem
	relays         []AdminAppRuntimeItem
	diagnostic_ids []string
}

struct AdminAppListenerSummary {
pub:
	id        string
	protocol  string
	transport string
	host      string
	port      int
	tls       bool
	control   bool
}

struct AdminAppRuntimeItem {
pub:
	id     string
	ref    string
	kind   string
	status string
}

struct AdminAppPipelineFlow {
pub:
	id         string
	group      string
	ingress    string
	match      string
	transforms []string
	policies   []string
	egress     string
	engine     string
	resources  []string
	flow       []string
}

struct AdminAppsSnapshot {
pub:
	apps        []AdminAppSummary
	listeners   []AdminAppListenerSummary
	pipelines   []AdminAppPipelineFlow
	diagnostics []runtime_plan.PlanDiagnostic
	counts      map[string]int
}

fn (app App) admin_apps_snapshot() AdminAppsSnapshot {
	plan := app.plan
	mut builder := AdminAppsBuilder.new(plan)
	for id, listener in plan.listeners {
		builder.add_listener(id, listener)
	}
	for pipeline in plan.pipelines {
		builder.add_pipeline(pipeline)
	}
	for id, engine in plan.engines {
		builder.add_engine(id, engine)
	}
	for id, adapter in plan.adapters {
		builder.add_adapter(id, adapter)
	}
	for id, resource in plan.resources {
		builder.add_resource(id, resource)
	}
	for id, provider in plan.providers {
		builder.add_provider(id, provider)
	}
	for id, relay_plan in plan.relays {
		builder.add_relay(id, relay_plan)
	}
	return builder.finish()
}

struct AdminAppsBuilder {
	plan runtime_plan.RuntimePlan
mut:
	apps      map[string]AdminAppSummary
	listeners []AdminAppListenerSummary
	pipelines []AdminAppPipelineFlow
}

fn AdminAppsBuilder.new(plan runtime_plan.RuntimePlan) AdminAppsBuilder {
	return AdminAppsBuilder{
		plan: plan
		apps: map[string]AdminAppSummary{}
	}
}

fn (mut builder AdminAppsBuilder) ensure_app(id string) {
	app_id := admin_app_id(id)
	if app_id in builder.apps {
		return
	}
	builder.apps[app_id] = AdminAppSummary{
		id:     app_id
		label:  app_id
		kind:   'unknown'
		status: 'ok'
	}
}

fn (mut builder AdminAppsBuilder) update_app(id string, next AdminAppSummary) {
	builder.apps[admin_app_id(id)] = next
}

fn (mut builder AdminAppsBuilder) add_listener(id string, listener runtime_plan.ListenerPlan) {
	app_id := builder.app_id_from_listener(id)
	builder.ensure_app(app_id)
	control := if control_listener := builder.plan.control.listener {
		control_listener.domain == .listener && control_listener.id == id
	} else {
		false
	}
	item := AdminAppListenerSummary{
		id:        id
		protocol:  listener.protocol
		transport: listener.transport
		host:      listener.host
		port:      listener.port
		tls:       listener.tls.enabled
		control:   control
	}
	builder.listeners << item
	mut app := builder.apps[admin_app_id(app_id)]
	app.listeners << item
	builder.update_app(app_id, app)
}

fn (mut builder AdminAppsBuilder) add_pipeline(pipeline runtime_plan.PipelinePlan) {
	app_id := builder.app_id_from_pipeline(pipeline)
	builder.ensure_app(app_id)
	flow := builder.pipeline_flow(pipeline)
	builder.pipelines << flow
	mut app := builder.apps[admin_app_id(app_id)]
	app.pipelines << flow
	builder.update_app(app_id, app)
}

fn (mut builder AdminAppsBuilder) add_engine(id string, engine runtime_plan.EnginePlan) {
	app_id := admin_app_id_from_scoped_id(id)
	builder.ensure_app(app_id)
	mut app := builder.apps[admin_app_id(app_id)]
	app.engines << AdminAppRuntimeItem{
		id:     id
		ref:    'engine:${id}'
		kind:   engine.kind
		status: 'configured'
	}
	builder.update_app(app_id, app)
}

fn (mut builder AdminAppsBuilder) add_adapter(id string, adapter runtime_plan.AdapterPlan) {
	app_id := builder.app_id_from_adapter(id)
	builder.ensure_app(app_id)
	mut app := builder.apps[admin_app_id(app_id)]
	app.adapters << AdminAppRuntimeItem{
		id:     id
		ref:    'adapter:${id}'
		kind:   adapter.kind
		status: 'configured'
	}
	builder.update_app(app_id, app)
}

fn (mut builder AdminAppsBuilder) add_resource(id string, resource runtime_plan.ResourcePlan) {
	app_id := builder.app_id_from_resource(id)
	builder.ensure_app(app_id)
	mut app := builder.apps[admin_app_id(app_id)]
	app.resources << AdminAppRuntimeItem{
		id:     id
		ref:    'resource:${id}'
		kind:   resource.kind
		status: 'configured'
	}
	builder.update_app(app_id, app)
}

fn (mut builder AdminAppsBuilder) add_provider(id string, provider runtime_plan.ProviderPlan) {
	app_id := admin_app_id_from_scoped_id(id)
	builder.ensure_app(app_id)
	mut app := builder.apps[admin_app_id(app_id)]
	app.providers << AdminAppRuntimeItem{
		id:     id
		ref:    'provider:${id}'
		kind:   if provider.protocol != '' { provider.protocol } else { provider.driver }
		status: 'configured'
	}
	builder.update_app(app_id, app)
}

fn (mut builder AdminAppsBuilder) add_relay(id string, relay_plan runtime_plan.RelayPlan) {
	app_id := admin_app_id_from_scoped_id(id)
	builder.ensure_app(app_id)
	mut app := builder.apps[admin_app_id(app_id)]
	app.relays << AdminAppRuntimeItem{
		id:     id
		ref:    'relay:${id}'
		kind:   relay_plan.mode
		status: 'configured'
	}
	builder.update_app(app_id, app)
}

fn (builder AdminAppsBuilder) finish() AdminAppsSnapshot {
	mut apps := builder.apps.values()
	for i, mut app in apps {
		app.kind = admin_app_kind(app)
		app.status = if app.diagnostic_ids.len > 0 { 'diagnostic' } else { 'ok' }
		app.listeners.sort(a.id < b.id)
		app.engines.sort(a.id < b.id)
		app.adapters.sort(a.id < b.id)
		app.resources.sort(a.id < b.id)
		app.providers.sort(a.id < b.id)
		app.relays.sort(a.id < b.id)
		app.pipelines.sort(a.id < b.id)
		apps[i] = app
	}
	apps.sort(a.id < b.id)
	mut listeners := builder.listeners.clone()
	listeners.sort(a.id < b.id)
	mut pipelines := builder.pipelines.clone()
	pipelines.sort(a.id < b.id)
	return AdminAppsSnapshot{
		apps:        apps
		listeners:   listeners
		pipelines:   pipelines
		diagnostics: builder.plan.diagnostics
		counts:      {
			'apps':        apps.len
			'listeners':   listeners.len
			'pipelines':   pipelines.len
			'engines':     builder.plan.engines.len
			'adapters':    builder.plan.adapters.len
			'providers':   builder.plan.providers.len
			'relays':      builder.plan.relays.len
			'diagnostics': builder.plan.diagnostics.len
		}
	}
}

fn (builder AdminAppsBuilder) app_id_from_listener(id string) string {
	for pipeline in builder.plan.pipelines {
		if pipeline.ingress.domain == .listener && pipeline.ingress.id == id {
			return builder.app_id_from_pipeline(pipeline)
		}
	}
	return admin_app_id_from_scoped_id(id)
}

fn (builder AdminAppsBuilder) app_id_from_pipeline(pipeline runtime_plan.PipelinePlan) string {
	if pipeline.group.starts_with('site:') {
		return admin_app_id(pipeline.group.all_after('site:'))
	}
	if pipeline.group.trim_space() != '' {
		return admin_app_id(pipeline.group.split('.')[0])
	}
	return admin_app_id_from_scoped_id(pipeline.id)
}

fn (builder AdminAppsBuilder) app_id_from_adapter(id string) string {
	for pipeline in builder.plan.pipelines {
		if pipeline.egress.domain == .adapter && pipeline.egress.id == id {
			return builder.app_id_from_pipeline(pipeline)
		}
	}
	return admin_app_id_from_scoped_id(id)
}

fn (builder AdminAppsBuilder) app_id_from_resource(id string) string {
	ref := 'resource:${id}'
	for adapter_id, adapter in builder.plan.adapters {
		if storage_ref := adapter.storage {
			if storage_ref.str() == ref {
				return builder.app_id_from_adapter(adapter_id)
			}
		}
	}
	for engine_id, engine in builder.plan.engines {
		for resource_ref in engine.resources {
			if resource_ref.str() == ref {
				return admin_app_id_from_scoped_id(engine_id)
			}
		}
	}
	if id.starts_with('db/') || id.starts_with('storage/') || id.starts_with('cache/') {
		return admin_app_id_from_scoped_id(id.all_after('/'))
	}
	return admin_app_id_from_scoped_id(id)
}

fn (builder AdminAppsBuilder) pipeline_flow(pipeline runtime_plan.PipelinePlan) AdminAppPipelineFlow {
	engine_ref := builder.pipeline_engine_ref(pipeline)
	resources := builder.pipeline_resource_refs(engine_ref, pipeline.egress)
	mut flow := []string{}
	flow << pipeline.ingress.str()
	flow << 'pipeline:${pipeline.id}'
	for transform in pipeline.transforms {
		flow << transform.str()
	}
	for policy in pipeline.policies {
		flow << policy.str()
	}
	flow << pipeline.egress.str()
	if engine_ref != '' {
		flow << engine_ref
	}
	for resource in resources {
		flow << resource
	}
	return AdminAppPipelineFlow{
		id:         pipeline.id
		group:      pipeline.group
		ingress:    pipeline.ingress.str()
		match:      admin_pipeline_match_label(pipeline.match)
		transforms: pipeline.transforms.map(it.str())
		policies:   pipeline.policies.map(it.str())
		egress:     pipeline.egress.str()
		engine:     engine_ref
		resources:  resources
		flow:       flow
	}
}

fn (builder AdminAppsBuilder) pipeline_engine_ref(pipeline runtime_plan.PipelinePlan) string {
	if pipeline.egress.domain != .adapter {
		return ''
	}
	adapter := builder.plan.adapters[pipeline.egress.id] or { return '' }
	if engine_ref := adapter.engine {
		return engine_ref.str()
	}
	return ''
}

fn (builder AdminAppsBuilder) pipeline_resource_refs(engine_ref string, egress runtime_plan.ResourceRef) []string {
	mut refs := []string{}
	if egress.domain == .adapter {
		if adapter := builder.plan.adapters[egress.id] {
			if storage_ref := adapter.storage {
				refs << storage_ref.str()
			}
		}
	}
	if engine_ref.starts_with('engine:') {
		engine_id := engine_ref.all_after('engine:')
		if engine := builder.plan.engines[engine_id] {
			for resource_ref in engine.resources {
				refs << resource_ref.str()
			}
		}
	}
	return refs
}

fn admin_app_kind(app AdminAppSummary) string {
	if app.relays.len > 0 {
		return 'relay'
	}
	if app.providers.len > 0 {
		return 'provider'
	}
	if app.resources.any(it.id == 'db/wordpress') || app.id.contains('wordpress') {
		return 'wordpress'
	}
	if app.adapters.any(it.kind == 'static') {
		return 'static'
	}
	if app.engines.any(it.kind == 'vjsx') {
		return 'vjsx'
	}
	if app.engines.any(it.kind.starts_with('php')) {
		return 'php'
	}
	return 'mixed'
}

fn admin_app_id(raw string) string {
	clean := raw.trim_space()
	if clean == '' {
		return 'default'
	}
	return clean
}

fn admin_app_id_from_scoped_id(raw string) string {
	clean := raw.trim_space()
	if clean == '' {
		return 'default'
	}
	if clean.contains('/') {
		return admin_app_id(clean.split('/')[0])
	}
	if clean.contains('.') {
		return admin_app_id(clean.split('.')[0])
	}
	return admin_app_id(clean)
}

fn admin_pipeline_match_label(match_plan runtime_plan.MatchPlan) string {
	mut parts := []string{}
	if match_plan.methods.len > 0 {
		parts << match_plan.methods.join(',')
	}
	if match_plan.hosts.len > 0 {
		parts << 'hosts=' + match_plan.hosts.join(',')
	}
	if match_plan.paths.len > 0 {
		parts << 'paths=' + match_plan.paths.join(',')
	}
	if match_plan.path_regexp != '' {
		parts << 'regexp=' + match_plan.path_regexp
	}
	if match_plan.path_regexps.len > 0 {
		parts << 'regexps=' + match_plan.path_regexps.join(',')
	}
	if match_plan.query.len > 0 {
		parts << 'query'
	}
	if match_plan.metadata.len > 0 {
		parts << 'metadata'
	}
	if parts.len == 0 {
		return '*'
	}
	return parts.join(' ')
}
