module executor

import os
import hash.fnv1a

fn test_streamed_signature_integer_encoding_preserves_signed_decimal() {
	for value in [i64(0), 1, -1, 1700000000, i64(9223372036854775807), i64(-9223372036854775807) - 1] {
		mut hash := VjsxSignatureHash{}
		hash.integer(value)
		assert hash.value == fnv1a.sum64_string(value.str())
	}
}

fn test_cached_source_scanner_matches_existing_fingerprints_and_detects_changes() {
	root := os.join_path(os.temp_dir(), 'vhttpd_cached_scanner_${os.getpid()}')
	os.mkdir_all(os.join_path(root, 'nested'))!
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.mjs')
	os.write_file(entry, 'export const x=1;')!
	os.write_file(os.join_path(root, 'nested', 'skip.mjs'), 'excluded')!
	os.mkdir_all(os.join_path(root, 'node_modules', 'package'))!
	os.write_file(os.join_path(root, 'node_modules', 'package', 'index.mjs'), 'excluded subtree')!
	config := VjsxRuntimeFacadeConfig{
		app_entry:         entry
		signature_root:    root
		signature_include: ['**/*.mjs']
		signature_exclude: ['nested/skip.mjs']
	}
	mut scanner := VjsxSourceScanner.new(config)
	assert scanner.probe() == config.source_probe()
	assert scanner.signature() == config.source_signature()
	os.utime(entry, 1700000000, 1700000000)!
	probe := scanner.probe()
	signature := scanner.signature()
	os.write_file(entry, 'export const x=2;')!
	os.utime(entry, 1700000000, 1700000000)!
	assert scanner.probe() == probe
	assert scanner.signature() != signature
	assert scanner.signature() == config.source_signature()
	added := os.join_path(root, 'nested', 'added.mjs')
	os.write_file(added, 'new file')!
	scanner.refresh_files()
	assert scanner.probe() == config.source_probe()
	assert scanner.signature() == config.source_signature()
	os.rm(added)!
	scanner.refresh_files()
	assert scanner.probe() == config.source_probe()
	assert scanner.signature() == config.source_signature()
	os.rmdir_all(root)!
	scanner.refresh_files()
	assert scanner.files.len == 0
	assert scanner.probe() == config.source_probe()
}

fn test_cached_source_scanner_detects_entry_type_changes_and_subtree_replacement() {
	root := os.join_path(os.temp_dir(), 'vhttpd_scanner_topology_${os.getpid()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.mjs')
	os.write_file(entry, 'export default 1;')!
	changed := os.join_path(root, 'changed.mjs')
	os.write_file(changed, 'old file')!
	config := VjsxRuntimeFacadeConfig{ app_entry: entry, signature_root: root }
	mut scanner := VjsxSourceScanner.new(config)
	assert scanner.signature() == config.source_signature()
	// Same parent entry names, different type: a file becomes a directory.
	os.rm(changed)!
	os.mkdir(changed)!
	os.write_file(os.join_path(changed, 'inner.mjs'), 'nested')!
	scanner.refresh_files()
	assert scanner.probe() == config.source_probe()
	assert scanner.signature() == config.source_signature()
	// Replacing the subtree and then restoring a regular file must not keep it.
	os.rmdir_all(changed)!
	os.write_file(changed, 'new file')!
	scanner.refresh_files()
	assert scanner.probe() == config.source_probe()
	assert scanner.signature() == config.source_signature()
	os.rm(changed)!
	scanner.refresh_files()
	assert scanner.signature() == config.source_signature()
}

fn test_cached_source_scanner_preserves_global_order_and_equal_count_path_changes() {
	root := os.join_path(os.temp_dir(), 'vhttpd_scanner_membership_${os.getpid()}')
	os.mkdir_all(os.join_path(root, 'a'))!
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'a.mjs')
	os.write_file(entry, 'export default 1;')!
	os.write_file(os.join_path(root, 'a', 'nested.mjs'), 'export const x=1;')!
	config := VjsxRuntimeFacadeConfig{ app_entry: entry, signature_root: root }
	mut scanner := VjsxSourceScanner.new(config)
	// DFS order differs from global path order for a/ and a.mjs.
	for _ in 0 .. 20 {
		scanner.refresh_files()
		assert scanner.probe() == config.source_probe()
		assert scanner.signature() == config.source_signature()
	}
	// Keep both directory and file counts unchanged while replacing names.
	os.mv(os.join_path(root, 'a'), os.join_path(root, 'b'))!
	os.mv(os.join_path(root, 'b', 'nested.mjs'), os.join_path(root, 'b', 'renamed.mjs'))!
	scanner.refresh_files()
	assert scanner.probe() == config.source_probe()
	assert scanner.signature() == config.source_signature()
	// A disappearing root must clear the retained sorted traversal too.
	os.rmdir_all(root)!
	scanner.refresh_files()
	assert scanner.probe() == config.source_probe()
	assert scanner.signature() == config.source_signature()
}
