module host

import crypto.sha256
import os

fn test_catalog_accepts_explicit_previews_without_weakening_default_stable_download() ! {
	sha := 'a'.repeat(12)
	tag := 'v0.1.0-dev.g' + sha
	assert normalize_runtime_tag(tag[1..])! == tag
	assert normalize_runtime_tag('https://github.com/guweigang/vhttpd/releases/tag/' + tag)! == tag
	for invalid in ['../bad', 'https://github.com/attacker/vhttpd/releases/tag/v1.2.3', 'v1.2.3?token=secret', 'v1.2.3\nheader'] {
		normalize_runtime_tag(invalid) or { continue }
		assert false, 'unsafe or invalid version accepted'
	}
	release := RuntimeRelease{tag_name: tag, prerelease: true, published_at: '2026-10-25T00:00:00Z', assets: [
		RuntimeReleaseAsset{name: 'vhttpd-workbench-macos-arm64-${tag[1..]}.zip', size: 100, browser_download_url: 'https://github.com/guweigang/vhttpd/releases/download/${tag}/mac.zip'},
		RuntimeReleaseAsset{name: 'vhttpd-workbench-macos-arm64-${tag[1..]}-SHA256SUMS.txt', size: 100, browser_download_url: 'https://github.com/guweigang/vhttpd/releases/download/${tag}/checks.txt'},
		RuntimeReleaseAsset{name: 'vhttpd-linux-arm64.tar.gz', size: 100, browser_download_url: 'https://github.com/guweigang/vhttpd/releases/download/${tag}/vhttpd-linux-arm64.tar.gz'},
		RuntimeReleaseAsset{name: 'vhttpd-linux-arm64.tar.gz.sha256', size: 100, browser_download_url: 'https://github.com/guweigang/vhttpd/releases/download/${tag}/vhttpd-linux-arm64.tar.gz.sha256'},
	]}
	mac := runtime_download_for(release, 'macos-arm64')!
	assert mac.channel == 'development' && mac.tag == tag
	linux := runtime_download_for(release, 'linux-arm64')!
	assert linux.platform == 'linux-arm64'
	runtime_download_for(release, 'linux-amd64') or {
		runtime_assets(release) or { return }
		assert false, 'preview silently accepted by stable default'
		return
	}
	assert false, 'wrong platform or preview silently accepted by stable default'
}

fn test_selected_release_provenance_survives_install_and_failed_checksum() ! {
	archive := os.getenv('VHTTPD_CATALOG_INSTALL_ARCHIVE')
	if archive == '' { return }
	previous := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	previous_binary := os.getenv_opt('VHTTPD_DESKTOP_BINARY')
	directory := '/tmp/vh-catalog-install-' + new_remote_id()!
	os.mkdir(directory, mode: 0o700)!
	defer {
		if old := previous { os.setenv('VHTTPD_DESKTOP_DATA_DIR', old, true) } else { os.unsetenv('VHTTPD_DESKTOP_DATA_DIR') }
		if old := previous_binary { os.setenv('VHTTPD_DESKTOP_BINARY', old, true) } else { os.unsetenv('VHTTPD_DESKTOP_BINARY') }
		os.rmdir_all(directory) or {}
	}
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', directory, true)
	os.unsetenv('VHTTPD_DESKTOP_BINARY')
	checksum := sha256.sum(os.read_bytes(archive)!).hex()
	tag := 'v0.1.0-dev.gaaaaaaaaaaaa'
	path := install_runtime_archive_tag(archive, checksum, tag, RuntimeJob{})!
	info := inspect_runtime(path, '', RuntimeJob{})
	assert info.ready && info.source.contains(tag)
	assert selected_runtime('', '')! == path
	install_runtime_archive_tag(archive, '0'.repeat(64), 'v1.2.3', RuntimeJob{}) or {
		assert selected_runtime('', '')! == path
		return
	}
	assert false, 'corrupt package replaced the selection'
}
