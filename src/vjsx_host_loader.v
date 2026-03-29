module main

import hash.fnv1a
import os
import vjsx
import vjsx.runtimejs

fn vjsx_entry_runs_as_module(app_entry string) !bool {
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

fn vjsx_fs_roots(config VjsxRuntimeFacadeConfig) []string {
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

fn runtime_relative_path(from string, to string) string {
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

fn runtime_import_specifier(from_path string, to_path string) string {
	mut rel := runtime_relative_path(os.dir(from_path), to_path)
	if !rel.starts_with('.') {
		rel = './' + rel
	}
	return rel.replace('\\', '/')
}

fn vjsx_lane_temp_root(app_entry string, idx int) string {
	entry_abs := os.abs_path(app_entry)
	entry_name := os.base(entry_abs).trim_space().replace(' ', '_')
	entry_hash := fnv1a.sum64_string(entry_abs).hex()
	cache_root := os.join_path(os.temp_dir(), 'vhttpd_vjsx')
	return os.join_path(cache_root, '${entry_name}.${entry_hash}.pid_${os.getpid()}.lane_${idx}.vjsbuild')
}

fn vjsx_lane_temp_root_for_signature(config VjsxRuntimeFacadeConfig, idx int, source_signature string) string {
	entry_abs := os.abs_path(config.app_entry)
	entry_name := os.base(entry_abs).trim_space().replace(' ', '_')
	cache_root := os.join_path(os.temp_dir(), 'vhttpd_vjsx')
	return os.join_path(cache_root, '${entry_name}.${source_signature}.pid_${os.getpid()}.lane_${idx}.vjsbuild')
}

fn load_inproc_vjsx_entry(mut ctx vjsx.Context, config VjsxRuntimeFacadeConfig, idx int, source_signature string, as_module bool) !vjsx.Value {
	temp_root := vjsx_lane_temp_root_for_signature(config, idx, source_signature)
	if !as_module {
		return runtimejs.run_runtime_entry(ctx, config.app_entry, false, temp_root)
	}
	if vjsx.is_typescript_file(config.app_entry) || vjsx.is_runtime_module_file(config.app_entry) {
		runtimejs.install_typescript_runtime(ctx)!
	}
	entry_path := runtimejs.build_runtime_module_entry(ctx, config.app_entry, true, temp_root)!
	loader_path := os.join_path(temp_root, '__vhttpd_loader__.mjs')
	loader_source :=
		'import * as __vhttpd_exports from "${runtime_import_specifier(loader_path, entry_path)}";\n' +
		'globalThis.__vhttpd_module_exports = __vhttpd_exports;\n' +
		'export default __vhttpd_exports.default;\n'
	os.write_file(loader_path, loader_source)!
	mut entry_result := ctx.run_file(loader_path, vjsx.type_module)!
	entry_result.free()
	return ctx.js_global('__vhttpd_module_exports')
}
