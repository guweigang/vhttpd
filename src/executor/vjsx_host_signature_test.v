module executor

import os
import hash.fnv1a

fn test_vjsx_signature_path_matches_supports_recursive_and_exact_patterns() {
	assert VjsxHostSignature.path_matches('apps/demo/app.mts', '**/*.mts')
	assert VjsxHostSignature.path_matches('apps/demo/app.mts', 'apps/**/*.mts')
	assert !VjsxHostSignature.path_matches('apps/demo/app.mts', 'ignore.mts')
	assert VjsxHostSignature.path_matches('ignore.mts', 'ignore.mts')
	assert VjsxHostSignature.path_matches('tmp/cache/file.json', 'tmp/**')
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
	matches := VjsxHostSignature.expand_globs(temp_dir, ['**/*.mts'])
	assert matches.len == 2
	assert matches[0].ends_with('/apps/demo/app.mts') || matches[1].ends_with('/apps/demo/app.mts')
	assert matches[0].ends_with('/ignore.mts') || matches[1].ends_with('/ignore.mts')
}

fn test_vjsx_signature_matching_files_preserves_relative_roots_excludes_and_order() {
	root := os.join_path(os.temp_dir(), 'vhttpd_signature_filter_${os.getpid()}')
	os.mkdir_all(os.join_path(root, 'nested'))!
	defer { os.rmdir_all(root) or {} }
	for name in ['z.mjs', 'a.mjs', 'nested/app.mjs', 'nested/ignored.mjs', 'other.txt'] {
		os.write_file(os.join_path(root, name), 'fixture')!
	}
	relative_root := VjsxHostPath.relative(os.getwd(), root)
	files := VjsxHostSignature.matching_files(relative_root,
		['*.mjs', '**/*.mjs', 'a.mjs'], ['nested/ignored.mjs'])
	assert files.map(it.rel) == ['a.mjs', 'nested/app.mjs', 'z.mjs']
	assert files.map(it.path) == files.map(os.join_path(root, it.rel))
	assert VjsxHostSignature.expand_globs(root, []string{}).len == 0
	assert VjsxHostSignature.matching_files(root, ['**/*.mjs'], ['**']).len == 0
}

fn test_vjsx_signature_streamed_hash_matches_fnv_for_binary_chunks_and_empty_files() {
	root := os.join_path(os.temp_dir(), 'vhttpd_signature_hash_${os.getpid()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'data.mjs')
	mut buffer := []u8{len: 65536}
	for size in [0, 1, 65535, 65536, 65537, 150000] {
		bytes := []u8{len: size, init: u8(index % 251)}
		os.write_file_array(path, bytes)!
		assert VjsxHostSignature.file_hash(path, mut buffer) == fnv1a.sum64(bytes).hex()
	}
	assert VjsxHostSignature.file_hash(os.join_path(root, 'missing'), mut buffer) == 'read_error'
}

fn test_vjsx_signature_full_refresh_detects_same_size_same_timestamp_changes() {
	root := os.join_path(os.temp_dir(), 'vhttpd_signature_content_${os.getpid()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'app.mjs')
	os.write_file(path, 'export const value = 1;')!
	os.utime(path, 1700000000, 1700000000)!
	config := VjsxRuntimeFacadeConfig{app_entry: path, signature_root: root}
	probe := config.source_probe()
	signature := config.source_signature()
	os.write_file(path, 'export const value = 2;')!
	os.utime(path, 1700000000, 1700000000)!
	assert config.source_probe() == probe
	assert config.source_signature() != signature
}
