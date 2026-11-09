module host

import app_bundle
import application_catalog
import config
import time

// Read the registered environment, including nested includes and v1 migration,
// through the runtime compiler. Never infer installations from directory names.
fn configured_workspace(path string) RuntimeWorkspace {
	if path == '' { return RuntimeWorkspace{} }
	plan := config.load_runtime_plan_file(path) or {
		return RuntimeWorkspace{ from_configuration: true, error: '无法读取本地应用配置；请检查运行环境配置及其引用文件。' }
	}
	projection := application_catalog.from_plan(plan)
	mut groups := []RuntimeApplication{}
	for app in projection.apps {
		mut identity := app_bundle.ApplicationIdentity{}
		mut identity_error := ''
		for engine in app.engines {
			found := app_bundle.engine_identity(path, engine.id) or {
				identity_error = 'application_identity_unavailable'
				continue
			}
			if found.app_id == '' { continue }
			if identity.app_id != '' && (identity.app_id != found.app_id || identity.installation_id != found.installation_id) {
				identity_error = 'application_binding_ambiguous'
				break
			}
			identity = found
		}
		groups << RuntimeApplication{
			id:             app.id
			label:          app.label
			status:         'configured'
			identity:       if identity_error == '' {
				identity
			} else {
				app_bundle.ApplicationIdentity{}
			}
			identity_error: identity_error
			listeners:      app.listeners.map(ApplicationListener{ id: it.id, protocol: it.protocol, host: it.host, port: it.port, tls: it.tls, control: it.control })
			engines:        app.engines.map(ApplicationItem{ id: it.id, kind: it.kind })
			pipelines:      app.pipelines.map(ApplicationPipeline{ id: it.id, ingress: it.ingress, engine: it.engine, egress: it.egress, resources: it.resources })
			resources:      app.resources.map(ApplicationItem{ id: it.id, kind: it.kind })
			relays:         app.relays.map(ApplicationItem{ id: it.id, kind: it.kind })
		}
	}
	mut applications := []RuntimeApplication{}
	for app in groups {
		if app.listeners.any(!it.control) || app.pipelines.any(it.engine != '') {
			applications << application_with_bindings(app, groups)
		}
	}
	return RuntimeWorkspace{
		inventory_known:    true
		from_configuration: true
		checked_at:         time.now().hhmmss()
		applications:       applications
	}
}
