module main

import dbx
import executor

// Optional EmbeddedHost capability. Credentials never enter JavaScript.
pub fn (mut app App) vjsx_database_backend() !executor.DatabaseBackend {
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
