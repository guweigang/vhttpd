module main

import ui2
import os
import crypto.sha256

fn test_font_layout_uses_shared_faces_without_changing_geometry() {
	root := ui2.screen(workbench_paper, [
		label('heading', '项目 Project 状态', 0, 0, 300, 24, workbench_ink),
		ui2.text_area('logs', 'HTTP latency 123 ms', ui2.rect(0, 80, 300, 100), ui2.BoxStyle{}, ui2.TextStyle{ font_family: 'Menlo', size: 11 }),
	])
	adapted := workbench_font_layout(root)
	assert adapted.children[0].text_style.font_family == workbench_ui_font
	assert adapted.children[1].text_style.font_family == workbench_mono_font
	assert adapted.children[1].text_style.size == 12
	assert adapted.children[0].frame == root.children[0].frame
	assert adapted.children[0].text == root.children[0].text
	assert adapted.children[1].frame == root.children[1].frame
}

fn test_mixed_logs_keep_the_same_monospace_family() {
	for text in ['HTTP 200', '家庭同步 HTTP 200', '中文，ABC 012'] {
		root := ui2.text_area('mixed', text, ui2.rect(0, 0, 300, 100), ui2.BoxStyle{}, ui2.TextStyle{ font_family: 'Menlo', size: 14 })
		adapted := workbench_font_layout(root)
		assert adapted.text_style.font_family == workbench_mono_font
	}
}

fn test_verified_font_cache_is_reusable_without_decoder() ! {
	root := os.join_path(os.temp_dir(), 'vhttpd-font-cache-test-${os.getpid()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	compressed := 'compressed fixture'
	decoded := 'decoded fixture'
	os.write_file(os.join_path(root, 'font.woff2'), compressed)!
	asset := WorkbenchFontAsset{ file: 'font.woff2', bytes: u64(compressed.len), sha256: sha256.hexhash(compressed), decoded_file: 'font.ttf', decoded_bytes: u64(decoded.len), decoded_sha256: sha256.hexhash(decoded) }
	cache := os.join_path(root, 'cache')
	os.mkdir_all(cache)!
	target := os.join_path(cache, '${asset.decoded_sha256}-${asset.decoded_file}')
	os.write_file(target, decoded)!
	assert cached_workbench_font(root, cache, os.join_path(root, 'no-decoder'), asset)! == target
	os.write_file(os.join_path(root, 'font.woff2'), 'corrupt')!
	if _ := cached_workbench_font(root, cache, os.join_path(root, 'no-decoder'), asset) {
		assert false
	}
}

fn create_font_cache_concurrently(path string, results chan bool) {
	ensure_workbench_font_cache(path) or {
		results <- false
		return
	}
	results <- true
}

fn test_font_cache_handles_concurrent_parent_directory_creation() ! {
	root := os.join_path(os.temp_dir(), 'vhttpd-font-cache-mkdir-${os.getpid()}')
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'new', 'nested', 'fonts')
	results := chan bool{cap: 8}
	for _ in 0 .. 8 { go create_font_cache_concurrently(path, results) }
	for _ in 0 .. 8 {
		assert <-results
	}
	assert os.is_dir(path)
}
