module main

import os
import json2
import crypto.sha256
import encoding.hex
import rand
import time
import ui2

struct WorkbenchFontAsset {
	file           string
	bytes          u64
	sha256         string
	role           string
	decoded_file   string
	decoded_bytes  u64
	decoded_sha256 string
}

struct WorkbenchFontLock {
	assets []WorkbenchFontAsset
}

fn workbench_font_hash(path string) !string {
	mut file := os.open(path)!
	defer { file.close() }
	mut digest := sha256.new()
	mut buffer := []u8{len: 65536}
	for {
		n := file.read(mut buffer) or {
			if err is os.Eof { break }
			return err
		}
		if n == 0 { break }
		digest.write(buffer[..n])!
	}
	return hex.encode(digest.sum([]))
}

fn valid_workbench_font(path string, bytes u64, checksum string) bool {
	if !os.is_file(path) || os.file_size(path) != bytes { return false }
	return (workbench_font_hash(path) or { return false }) == checksum
}

fn ensure_workbench_font_cache(cache string) ! {
	// mkdir_all may race while another process creates an intermediate directory.
	for attempt in 0 .. 8 {
		os.mkdir_all(cache) or {
			if !os.is_dir(cache) {
				if attempt == 7 { return err }
				time.sleep(5 * time.millisecond)
				continue
			}
		}
		$if !windows {
			os.chmod(cache, 0o700)!
		}
		return
	}
}

fn cached_workbench_font(directory string, cache string, decoder string, asset WorkbenchFontAsset) !string {
	source := os.join_path(directory, asset.file)
	if !valid_workbench_font(source, asset.bytes, asset.sha256) {
		return error('字体资源校验失败，请重新解压完整工作台安装包。')
	}
	ensure_workbench_font_cache(cache)!
	target := os.join_path(cache, '${asset.decoded_sha256}-${asset.decoded_file}')
	if valid_workbench_font(target, asset.decoded_bytes, asset.decoded_sha256) { return target }
	if !os.is_file(decoder) {
		return error('字体解码器缺失，请重新解压完整工作台安装包。')
	}
	temporary := target + '.${rand.ulid()}.tmp'
	defer { os.rm(temporary) or {} }
	mut child := os.new_process(decoder)
	child.set_args([source, temporary])
	child.run()
	deadline := time.now().unix_milli() + 15000
	for child.is_alive() {
		if time.now().unix_milli() > deadline {
			child.signal_kill()
			break
		}
		time.sleep(10 * time.millisecond)
	}
	child.wait()
	code := child.code
	child.close()
	if code != 0 || !valid_workbench_font(temporary, asset.decoded_bytes, asset.decoded_sha256) {
		return error('字体解码失败，请重新解压完整工作台安装包。')
	}
	if valid_workbench_font(target, asset.decoded_bytes, asset.decoded_sha256) { return target }
	if os.exists(target) {
		if valid_workbench_font(target, asset.decoded_bytes, asset.decoded_sha256) { return target }
		os.rm(target) or {
			if valid_workbench_font(target, asset.decoded_bytes, asset.decoded_sha256) {
				return target
			}
			return err
		}
	}
	os.rename(temporary, target) or {
		if !valid_workbench_font(target, asset.decoded_bytes, asset.decoded_sha256) { return err }
	}
	return target
}

fn load_workbench_fonts(directory string) !map[string]string {
	font_lock := json2.decode[WorkbenchFontLock]($embed_file('assets/fonts.lock.json').to_string())!
	mut helper := os.join_path(os.dir(directory), 'vhttpd-fontdecode')
	$if windows {
		helper = os.join_path(os.dir(directory), 'vhttpd-fontdecode.exe')
	}
	mut cache_root := os.getenv('XDG_CACHE_HOME')
	if cache_root == '' || !os.is_abs_path(cache_root) {
		cache_root = os.join_path(os.home_dir(), '.cache')
	}
	cache := os.join_path(cache_root, 'vhttpd-workbench', 'fonts')
	mut paths := map[string]string{}
	for asset in font_lock.assets {
		if asset.role !in ['regular', 'bold'] { continue }
		paths[asset.role] = cached_workbench_font(directory, cache, helper, asset)!
	}
	if paths.len != 2 { return error('字体资源不完整。') }
	return paths
}

fn run_font_smoke() ! {
	configure_workbench_fonts()!
	for bold in [false, true] {
		for size in [12.0, 14.0, 15.0, 18.0] {
			element := workbench_font_layout(ui2.label('font-check', '', ui2.rect(0, 0, 0, 0), ui2.TextStyle{ font_family: 'monospace', size: size, bold: bold }))
			style := element.text_style
			a := ui2.measure_layout_text('AA'.repeat(32), style, -1)!
			b := ui2.measure_layout_text('中'.repeat(32), style, -1)!
			c := ui2.measure_layout_text('A中'.repeat(32), style, -1)!
			d := ui2.measure_layout_text('AAA'.repeat(32), style, -1)!
			delta := a.width - b.width
			mixed_delta := c.width - d.width
			if delta < -0.01 || delta > 0.01 || mixed_delta < -0.01 || mixed_delta > 0.01 {
				return error('字体等宽校验失败：size=${size} bold=${bold} delta=${delta} mixed=${mixed_delta}')
			}
		}
	}
	println('PASS bundled WOFF2 fonts, verified decoded cache, regular/bold and Latin/CJK alignment')
}
