module executor

import log
import vjsx
import vjsx.runtimejs

struct InProcVjsxRuntimeSessionFactory {}

struct InProcVjsxRuntimeProfileLog {}

fn InProcVjsxRuntimeSessionFactory.new(config VjsxRuntimeFacadeConfig) !&vjsx.RuntimeSession {
	asset_root := VjsxHostLoader.asset_root()
	session_value := match config.runtime_profile {
		'', 'script' {
			runtimejs.new_script_runtime_session(vjsx.ContextConfig{}, vjsx.ScriptRuntimeConfig{
				fs_roots:     config.fs_roots()
				process_args: [config.app_entry]
				asset_root:   asset_root
			})
		}
		'node' {
			runtimejs.new_node_runtime_session(vjsx.ContextConfig{}, vjsx.NodeRuntimeConfig{
				fs_roots:     config.fs_roots()
				process_args: [config.app_entry]
				asset_root:   asset_root
			})
		}
		else {
			return error('inproc_vjsx_executor_unsupported_runtime_profile:${config.runtime_profile}')
		}
	}

	// Keep the RuntimeSession on the heap; lane hosts outlive ensure_lane_host().
	mut session := session_value
	return &session
}

fn InProcVjsxRuntimeProfileLog.kind_name(kind vjsx.RuntimeProfileKind) string {
	return match kind {
		.unknown { 'unknown' }
		.runtime_minimal { 'runtime_minimal' }
		.script { 'script' }
		.node_minimal { 'node_minimal' }
		.node { 'node' }
	}
}

fn InProcVjsxRuntimeProfileLog.write(lane_id string, idx int, runtime_profile string, ctx &vjsx.Context) {
	snapshot := vjsx.runtime_profile_snapshot(ctx)
	kind := snapshot.infer_kind()
	expected_kind := match runtime_profile {
		'', 'script' { vjsx.RuntimeProfileKind.script }
		'node' { vjsx.RuntimeProfileKind.node }
		else { vjsx.RuntimeProfileKind.unknown }
	}

	missing := if expected_kind == .unknown {
		[]string{}
	} else {
		snapshot.missing_for(expected_kind)
	}
	log.debug('[vhttpd] vjsx runtime profile lane=${lane_id} idx=${idx} configured=${runtime_profile} inferred=${InProcVjsxRuntimeProfileLog.kind_name(kind)} expected=${InProcVjsxRuntimeProfileLog.kind_name(expected_kind)} missing=${missing.join(',')} modules=${ctx.runtime_modules().join(',')}')
}

fn InProcVjsxRuntimeProfileLog.write_diagnostic(diagnostic vjsx.RuntimeSessionDiagnostic) {
	log.warn('[vhttpd] vjsx runtime diagnostic session=${diagnostic.session_id} kind=${diagnostic.kind} generation=${diagnostic.wakeup_generation} at_ms=${diagnostic.at_ms} message=${diagnostic.message}')
}

// C callback trampoline: V static methods passed directly to
// RuntimeSession.set_diagnostic_handler can emit undeclared __static__ symbols
// in generated C, so the callback boundary must stay as a plain function.
fn inproc_vjsx_runtime_session_diagnostic_handler(diagnostic vjsx.RuntimeSessionDiagnostic) {
	InProcVjsxRuntimeProfileLog.write_diagnostic(diagnostic)
}
