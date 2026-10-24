module executor

import dbx
import net.http
import os
import provider
import time

struct DatabaseTestHost {
	NoOpAppFacade
	access dbx.AsyncDatabaseAccess
}

pub fn (mut h DatabaseTestHost) vjsx_database_backend() !DatabaseBackend {
	mut database := dbx.AsyncDatabase.new(h.access)
	return DatabaseBackend{
		run_fn:   fn [mut database] (request string, cancelled fn () bool) !string {
			return database.run_json(request, cancelled)
		}
		close_fn: fn [mut database] () { database.close() }
	}
}

fn database_test_dispatch(exec InProcVjsxExecutor, mut host DatabaseTestHost, path string) string {
	result := exec.dispatch_http_with_host(mut host, HttpLogicDispatchRequest{
		method:     'GET'
		path:       path
		req:        http.Request{ method: .get, url: path, host: 'test.local' }
		request_id: path
		trace_id:   path
	}) or { panic(err) }
	assert result.response.status == 200, result.response.body
	return result.response.body
}

fn database_test_parallel(exec InProcVjsxExecutor, access dbx.AsyncDatabaseAccess) string {
	mut host := DatabaseTestHost{ access: access }
	return database_test_dispatch(exec, mut host, '/parallel-shared')
}

fn test_database_api_fails_closed_and_validates_options() {
	root := os.join_path(os.temp_dir(), 'vhttpd-db-unavailable-${os.getpid()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.js')
	os.write_file(entry, '
		globalThis.__vhttpd_handle = async ctx => {
			const db = ctx.runtime.db;
			const expect = async (pending, name, message) => {
				try { await pending; } catch (e) {
					if (e.name !== name || (message && e.message !== message)) throw e;
					return;
				}
				throw Error("unexpected success");
			};
			await expect(db.query("SELECT 1"), "Error", "database_unavailable");
			for (const timeoutMs of [0, -1, NaN, Infinity, 2147483648, 1.5]) {
				await expect(db.query("SELECT 1", [], {timeoutMs}), "TypeError");
			}
			await expect(db.query("SELECT ?", [1]), "TypeError");
			await expect(db.query("SELECT 1", [], {signal: {}}), "TypeError");
			await expect(db.query(""), "TypeError");
			return ctx.text("unavailable-ok");
		};
	') or { panic(err) }
	for profile in ['node', 'script'] {
		exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1, app_entry: entry, module_root: root, runtime_profile: profile })
		mut host := NoOpAppFacade{}
		result := exec.dispatch_http_with_host(mut host, HttpLogicDispatchRequest{ method: 'GET', path: '/', req: http.Request{ method: .get, url: '/', host: 'test.local' } }) or { panic(err) }
		assert result.response.status == 200, result.response.body
		assert result.response.body == 'unavailable-ok'
		exec.close()
	}
}

fn test_database_native_mysql_and_postgresql_async() {
	$if enable_db ? {
		for driver in ['mysql', 'pgsql'] {
			port := os.getenv(if driver == 'mysql' {
				'VHTTPD_TEST_MYSQL_PORT'
			} else {
				'VHTTPD_TEST_PG_PORT'
			}).int()
			if port == 0 {
				println('SKIP ${driver}: set VHTTPD_TEST_MYSQL_PORT / VHTTPD_TEST_PG_PORT for isolated databases')
				continue
			}
			mut owner := &dbx.PoolOwner{}
			settings := provider.DbRuntimeSettings{
				enabled:   true
				driver:    driver
				host:      '127.0.0.1'
				port:      port
				username:  if driver == 'mysql' {
					'root'
				} else {
					'vhttpd_test'
				}
				database:  'vhttpd_async_test'
				pool_size: 2
			}
			mut host := DatabaseTestHost{ access: dbx.AsyncDatabaseAccess{ settings: settings, owner: owner } }
			root := os.join_path(os.temp_dir(), 'vhttpd-db-${driver}-${os.getpid()}-${time.now().unix_micro()}')
			os.mkdir_all(root) or { panic(err) }
			entry := os.join_path(root, 'app.js')
			os.write_file(entry, $embed_file('testdata/database_async.js').to_string().replace('__DRIVER__', driver)) or { panic(err) }
			exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1, app_entry: entry, module_root: root, runtime_profile: 'node' })
			for path in ['setup', 'parallel', 'transactions', 'cancel-timeout', 'transaction-cancel',
				'bounds'] {
				assert database_test_dispatch(exec, mut host, '/${path}') == '${path}-ok'
				println('${driver} ${path}: ok')
			}
			assert database_test_dispatch(exec, mut host, '/detached') == 'started'
			time.sleep(400 * time.millisecond)
			// No HTTP dispatch pumps completion during the sleep.
			assert database_test_dispatch(exec, mut host, '/state') == 'done'
			multi := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 2, app_entry: entry, module_root: root, runtime_profile: 'node' })
			assert database_test_dispatch(multi, mut host, '/state') == 'pending'
			assert database_test_dispatch(multi, mut host, '/state') == 'pending'
			// Across lanes the shared two-connection pool still bounds admission.
			clock := time.new_stopwatch()
			left := spawn database_test_parallel(multi, host.access)
			right := spawn database_test_parallel(multi, host.access)
			assert left.wait() == 'parallel-ok'
			assert right.wait() == 'parallel-ok'
			println('${driver} two lanes / four queries / pool=2: ${clock.elapsed().milliseconds()}ms')
			assert clock.elapsed() < 950 * time.millisecond
			multi.close()
			assert database_test_dispatch(exec, mut host, '/close') == 'closing'
			exec.close()
			// Physical SQL can finish after lane close; wait for lease cleanup by
			// borrowing the entire pool, then verify rollback and no autocommit leak.
			time.sleep(400 * time.millisecond)
			mut check_db := dbx.AsyncDatabase.new(host.access)
			result := check_db.run(dbx.Request{ op: 'query', sql_text: 'SELECT COUNT(*) AS n FROM vjsx_async_items' }, fn () bool {
				return false
			}) or { panic(err) }
			assert result.rows[0]['n'] == '1'
			check_db.close()
			owner.close()
			os.rmdir_all(root) or {}
			println('${driver} detached wakeup / close rollback: ok')
		}
	} $else {
		println('SKIP database integration: compile with -d enable_db')
	}
}
