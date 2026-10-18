module executor

import os
import json2
import vjsx
import vjsx.runtimejs

const vhttpd_vjsx_asset_env = 'VJSX_ASSET_ROOT'

struct VjsxHostLoader {}

struct VjsxHostPath {}

pub fn VjsxHostLoader.asset_root() string {
	return os.getenv(vhttpd_vjsx_asset_env).trim_space()
}

fn VjsxHostLoader.entry_runs_as_module(app_entry string) !bool {
	if vjsx.is_typescript_file(app_entry) {
		return true
	}
	if app_entry.ends_with('.mjs') || app_entry.ends_with('.cjs') || app_entry.ends_with('.mts')
		|| app_entry.ends_with('.cts') {
		return true
	}
	if app_entry.ends_with('.js') {
		return false
	}
	return error('inproc_vjsx_executor_unsupported_entry:${app_entry}')
}

fn (config VjsxRuntimeFacadeConfig) fs_roots() []string {
	mut roots := []string{}
	if config.module_root.trim_space() != '' {
		roots << config.module_root
	}
	if config.app_entry.trim_space() != '' {
		roots << os.dir(config.app_entry)
	}
	roots << os.getwd()
	return roots.filter(it.trim_space() != '')
}

fn VjsxHostPath.relative(from string, to string) string {
	from_abs := os.abs_path(from)
	to_abs := os.abs_path(to)
	sep := os.path_separator.str()
	from_parts := from_abs.split(sep).filter(it.len > 0)
	to_parts := to_abs.split(sep).filter(it.len > 0)
	mut common := 0
	for common < from_parts.len && common < to_parts.len && from_parts[common] == to_parts[common] {
		common++
	}
	mut parts := []string{}
	for _ in common .. from_parts.len {
		parts << '..'
	}
	for part in to_parts[common..] {
		parts << part
	}
	if parts.len == 0 {
		return '.'
	}
	return parts.join(sep)
}

fn VjsxHostPath.import_specifier(from_path string, to_path string) string {
	mut rel := VjsxHostPath.relative(os.dir(from_path), to_path)
	if !rel.starts_with('.') {
		rel = './' + rel
	}
	return rel.replace('\\', '/')
}

fn VjsxHostLoader.default_build_root() string {
	return os.join_path(os.temp_dir(), 'vhttpd_vjsx')
}

fn (config VjsxRuntimeFacadeConfig) build_root_path() string {
	if config.build_root.trim_space() != '' {
		return os.abs_path(config.build_root)
	}
	return VjsxHostLoader.default_build_root()
}

// Naming prefix only. A path is owned only after exclusive directory reservation.
pub fn (config VjsxRuntimeFacadeConfig) lane_temp_root(idx int, source_signature string) string {
	entry_abs := os.abs_path(config.app_entry)
	entry_name := os.base(entry_abs).trim_space().replace(' ', '_')
	cache_root := config.build_root_path()
	return os.join_path(cache_root,
		'${entry_name}.${source_signature}.pid_${os.getpid()}.lane_${idx}.vjsxbuild')
}

fn VjsxHostLoader.load_entry(mut ctx vjsx.Context, config VjsxRuntimeFacadeConfig, temp_root string, as_module bool) !vjsx.Value {
	if !as_module {
		entry := os.real_path(config.app_entry)
		runtimejs.install_typescript_runtime(ctx)!
		if runtimejs.is_commonjs_module(ctx, entry)! {
			// The generic runner deletes its mirror as soon as evaluation returns.
			// Lane handlers may import later: retain this tree until host.destroy().
			emitted := runtimejs.build_runtime_module_entry(ctx, entry, true, temp_root)!
			return ctx.run_file(emitted, vjsx.type_module)
		}
		// Ordinary .js entries keep global-script scope and completion semantics.
		return ctx.run_file(entry, vjsx.type_global)
	}
	if vjsx.is_typescript_file(config.app_entry) || vjsx.is_runtime_module_file(config.app_entry) {
		runtimejs.install_typescript_runtime(ctx)!
	}
	entry_path := runtimejs.build_runtime_module_entry(ctx, os.real_path(config.app_entry), true, temp_root)!
	loader_path := os.join_path(temp_root, '__vhttpd_loader__.mjs')
	loader_source :=
		'import * as __vhttpd_exports from "${VjsxHostPath.import_specifier(loader_path, entry_path)}";\n' +
			'globalThis.__vhttpd_module_exports = __vhttpd_exports;\n' +
			'export default __vhttpd_exports.default;\n'
	os.write_file(loader_path, loader_source)!
	mut entry_result := ctx.run_file(loader_path, vjsx.type_module)!
	entry_result.free()
	return ctx.js_global('__vhttpd_module_exports')
}

// Only the already prepared entry crosses this bridge. RuntimeSession still
// creates and owns its managed module handle; the lane owns emitted files.
fn VjsxHostLoader.import_prepared_entry(mut session vjsx.RuntimeSession, entry string) !vjsx.ScriptModule {
	session.set_runtime_bridge(vjsx.RuntimeSessionBridge{
		run:         runtimejs.run_runtime_entry
		load_module: vjsx_host_load_prepared_module
	})
	defer { session.set_runtime_bridge(runtimejs.runtime_session_bridge()) }
	return session.import_module(entry)
}

// Callback stays a plain function for V's generated C function-pointer ABI.
fn vjsx_host_load_prepared_module(ctx &vjsx.Context, entry string, _temp_root string) !vjsx.Value {
	wrapper := os.join_path(os.dir(entry), '__vhttpd_lane_loader__.mjs')
	specifier := VjsxHostPath.import_specifier(wrapper, entry)
	global := ctx.js_global()
	defer {
		global.delete('__vhttpd_lane_exports')
		global.free()
	}
	encoded := json2.encode(specifier, escape_unicode: true, time_as_unix: true)
	mut evaluated := ctx.js_eval('import * as __vhttpd_lane_exports from ${encoded}; globalThis.__vhttpd_lane_exports = __vhttpd_lane_exports;', wrapper, vjsx.type_module)!
	evaluated.free()
	ctx.end()
	exports := global.get('__vhttpd_lane_exports')
	if exports.is_undefined() || exports.is_null() {
		exports.free()
		return error('inproc_vjsx_executor_module_namespace_missing:${entry}')
	}
	return exports
}
