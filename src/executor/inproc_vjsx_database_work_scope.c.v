module executor

import builtin.closure
import log
import vjsx

#include "@VMODROOT/src/executor/vjsx_database_work_scope.h"
#flag @VMODROOT/src/executor/vjsx_database_work_scope.c

fn C.vhttpd_database_scope_set(voidptr)
fn C.vhttpd_database_scope_get() voidptr

$if gcboehm ? {
	#include <gc.h>
	fn C.GC_reachable_here(voidptr)
}

struct VjsxDatabaseWork {
	database     DatabaseBackend
	req          DatabaseWireRequest
	request_json string
	port         vjsx.RuntimeHostAsyncCompletionPort
	token        vjsx.RuntimeHostAsyncCancelToken
}

fn run_scoped_database_work(work &VjsxDatabaseWork) ! {
	defer {
		// A pointer kept only in C thread-local storage is not a Boehm root.
		$if gcboehm ? {
			C.GC_reachable_here(voidptr(work))
		}
	}
	mut lifetime := closure.new_lifetime()
	defer { lifetime.dispose() or { log.error('database callback cleanup: ${err}') } }
	C.vhttpd_database_scope_set(voidptr(work))
	defer { C.vhttpd_database_scope_set(unsafe { nil }) }
	lifetime.frame(vjsx_database_scoped_callback)!
}

fn vjsx_database_scoped_callback() {
	work := unsafe { &VjsxDatabaseWork(C.vhttpd_database_scope_get()) }
	vjsx_database_worker_run(work.database, work.req, work.request_json, work.port, work.token)
}
