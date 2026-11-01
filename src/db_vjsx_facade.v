module main

import dbx
import executor

// Optional EmbeddedHost capability. Credentials never enter JavaScript.
pub fn (mut app App) vjsx_database_backend() !executor.DatabaseBackend {
	view := app.pipeline_dispatch_view()
	if resource := view.plan.listener_resource(app.app_build_cfg.plan_listener_id, 'db') {
		if resource.options.strings['relay'] != '' {
			return app.relay_database_backend(resource)
		}
	}
	app.mu.@lock()
	if !app.transport.db.enabled {
		app.mu.unlock()
		return error('database_disabled')
	}
	access := dbx.AsyncDatabaseAccess{ settings: app.transport.db.settings(), owner: app.transport.db.pool_owner }
	app.mu.unlock()
	mut database := dbx.AsyncDatabase.new(access)
	return executor.DatabaseBackend{
		run_fn:   fn [mut database] (request string, cancelled fn () bool) !string {
			return database.run_json(request, cancelled)
		}
		close_fn: fn [mut database] () { database.close() }
	}
}
