module main

import os

fn test_vjsx_signature_path_matches_supports_recursive_and_exact_patterns() {
	assert vjsx_signature_path_matches('apps/demo/app.mts', '**/*.mts')
	assert vjsx_signature_path_matches('apps/demo/app.mts', 'apps/**/*.mts')
	assert !vjsx_signature_path_matches('apps/demo/app.mts', 'ignore.mts')
	assert vjsx_signature_path_matches('ignore.mts', 'ignore.mts')
	assert vjsx_signature_path_matches('tmp/cache/file.json', 'tmp/**')
}

fn test_vjsx_signature_expand_globs_collects_matches_without_os_glob() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_signature_expand_globs_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(os.join_path(temp_dir, 'apps', 'demo')) or { panic(err) }
	os.write_file(os.join_path(temp_dir, 'apps', 'demo', 'app.mts'), 'export const ok = true;\n') or {
		panic(err)
	}
	os.write_file(os.join_path(temp_dir, 'ignore.mts'), 'export const ignore = true;\n') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	matches := vjsx_signature_expand_globs(temp_dir, ['**/*.mts'])
	assert matches.len == 2
	assert matches[0].ends_with('/apps/demo/app.mts') || matches[1].ends_with('/apps/demo/app.mts')
	assert matches[0].ends_with('/ignore.mts') || matches[1].ends_with('/ignore.mts')
}
