module host

import os
import time

fn test_runtime_versions_and_official_release_contract() ! {
	assert runtime_version_text('0.1.0\n')! == '0.1.0'
	assert runtime_version_text('vhttpd 1.2.3-rc.1')! == '1.2.3-rc.1'
	for invalid in ['unknown', '1.2', '../1.2.3', '0.1.0\nsecret', '1.2.3;evil'] {
		runtime_version_text(invalid) or { continue }
		assert false, 'invalid version accepted'
	}
	release := RuntimeRelease{
		tag_name: 'v1.2.3'
		assets:   [
			RuntimeReleaseAsset{ name: 'vhttpd-workbench-macos-arm64-1.2.3.zip', size: 100, browser_download_url: 'https://github.com/guweigang/vhttpd/releases/download/v1.2.3/package.zip' },
			RuntimeReleaseAsset{ name: 'vhttpd-workbench-macos-arm64-1.2.3-SHA256SUMS.txt', size: 100, browser_download_url: 'https://github.com/guweigang/vhttpd/releases/download/v1.2.3/checksums.txt' },
		]
	}
	archive, sums := runtime_assets(release)!
	assert archive.name.ends_with('.zip') && sums.name.ends_with('SHA256SUMS.txt')
	for bad in [RuntimeRelease{ ...release, prerelease: true },
		RuntimeRelease{ ...release, assets: [] }] {
		runtime_assets(bad) or { continue }
		assert false, 'incomplete release accepted'
	}
	assert !official_asset_url('https://github.com/attacker/vhttpd/releases/download/package')
	assert !official_asset_url('http://github.com/guweigang/vhttpd/releases/download/package')
	assert checksum_for('a'.repeat(64) + '  package.zip\n', 'package.zip')! == 'a'.repeat(64)
}

fn test_archive_paths_symlinks_and_expansion_limit() ! {
	details := '-rwxr-xr-x  2.0 unx 1000 b- defN 26-Oct-19 vhttpd-workbench.app/Contents/Resources/runtime/vhttpd'
	validate_archive_listing('vhttpd-workbench.app/Contents/Resources/runtime/vhttpd', details)!
	for path in ['/tmp/escape', '../escape', 'app/../../escape', 'app\\escape', 'app\napp'] {
		validate_archive_listing(path, details) or { continue }
		assert false, 'unsafe archive accepted'
	}
	validate_archive_listing('app', 'lrwxr-xr-x 2.0 unx 100 b- defN app') or {
		validate_archive_listing('app', '-rwxr-xr-x 2.0 unx 999999999 b- defN app') or { return }
	}
	assert false, 'unsafe archive size or symlink accepted'
}

fn test_runtime_selection_persists_and_inspection_is_bounded() ! {
	previous := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	override := os.getenv_opt('VHTTPD_DESKTOP_BINARY')
	dir := os.join_path(os.real_path(os.temp_dir()), 'runtime-selection-${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		if old := previous {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', old, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		if old := override {
			os.setenv('VHTTPD_DESKTOP_BINARY', old, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_BINARY')
		}
		os.rmdir_all(dir) or {}
	}
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', dir, true)
	os.unsetenv('VHTTPD_DESKTOP_BINARY')
	binary := os.join_path(dir, 'with spaces', 'vhttpd')
	os.mkdir_all(os.dir(binary))!
	os.write_file(binary, '#!/bin/sh\nprintf "0.1.0\\n"\n')!
	os.chmod(binary, 0o755)!
	save_runtime_selection(binary)!
	assert selected_runtime('/test/App.app/Contents/MacOS/workbench', '/development')! == binary
	info := inspect_runtime(binary, '/test/App.app/Contents/MacOS/workbench', RuntimeJob{})
	assert info.ready && info.version == '0.1.0'
	assert os.stat(os.join_path(dir, 'runtime-selection.json'))!.mode & 0o777 == 0o600
	os.rm(binary)!
	assert !inspect_runtime(binary, '', RuntimeJob{}).ready
	assert selected_runtime('/test/App.app/Contents/MacOS/workbench', '/development')! == binary
	job := RuntimeJob{}
	job.cancel <- true
	started := time.ticks()
	job.command('/bin/sleep', ['60'], 1000) or {
		assert time.ticks() - started < 2000
		return
	}
	assert false, 'cancelled child was left running'
}
