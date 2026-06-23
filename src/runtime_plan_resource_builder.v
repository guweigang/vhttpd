module main

import provider
import runtime_plan

fn db_runtime_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string) provider.DbRuntimeSettings {
	resource := listener_resource_plan(plan, listener_id, 'db') or {
		return provider.DbRuntimeSettings{}
	}
	driver := provider.normalize_db_driver(resource.kind)
	return provider.DbRuntimeSettings{
		enabled:      true
		socket:       if resource.options.strings['socket'] != '' {
			resource.options.strings['socket']
		} else {
			'tmp/vhttpd-db.sock'
		}
		driver:       driver
		pool_name:    if resource.options.strings['pool_name'] != '' {
			resource.options.strings['pool_name']
		} else {
			'default'
		}
		host:         db_plan_host(resource)
		port:         db_plan_port(resource, driver)
		username:     resource.options.strings['username']
		password:     resource.options.strings['password']
		database:     db_plan_database(resource, driver)
		pool_size:    if resource.options.ints['pool_size'] > 0 {
			resource.options.ints['pool_size']
		} else {
			5
		}
		idle_ping_ms: resource.options.ints['idle_ping_ms']
		init_sql:     resource.options.string_lists['init_sql'].clone()
	}
}

fn cache_runtime_settings_from_plan(plan runtime_plan.RuntimePlan, listener_id string) (bool, string) {
	resource := listener_resource_plan(plan, listener_id, 'cache') or { return false, '' }
	return true, resource.options.strings['socket']
}

fn listener_resource_plan(plan runtime_plan.RuntimePlan, listener_id string, category string) ?runtime_plan.ResourcePlan {
	engine := listener_default_engine_plan(plan, listener_id) or { return none }
	for reference in engine.resources {
		if reference.domain != .resource {
			continue
		}
		resource := plan.resources[reference.id] or { continue }
		if resource.category == category {
			return resource
		}
	}
	return none
}

fn listener_default_engine_plan(plan runtime_plan.RuntimePlan, listener_id string) ?runtime_plan.EnginePlan {
	for pipeline in plan.pipelines {
		if pipeline.ingress.domain != .listener || pipeline.ingress.id != listener_id
			|| !pipeline.id.ends_with('_fallback') || pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { return none }
		engine_ref := adapter.engine or { return none }
		return plan.engines[engine_ref.id] or { return none }
	}
	return none
}

fn db_plan_host(resource runtime_plan.ResourcePlan) string {
	if resource.options.strings['host'] != '' {
		return resource.options.strings['host']
	}
	return '127.0.0.1'
}

fn db_plan_port(resource runtime_plan.ResourcePlan, driver string) int {
	if resource.options.ints['port'] > 0 {
		return resource.options.ints['port']
	}
	return if driver == 'pgsql' { 5432 } else { 3306 }
}

fn db_plan_database(resource runtime_plan.ResourcePlan, driver string) string {
	if resource.options.strings['database'] != '' {
		return resource.options.strings['database']
	}
	return if driver == 'pgsql' { 'postgres' } else { 'mysql' }
}
