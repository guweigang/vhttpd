module host

fn update_fixture_release(tag string, version string, platform string) RuntimeRelease {
	extension := if platform.starts_with('linux-') { 'tar.gz' } else { 'zip' }
	name := 'vhttpd-workbench-${platform}-${version}.${extension}'
	return RuntimeRelease{
		tag_name: tag
		assets: [RuntimeReleaseAsset{
			name: name
			size: 100
			browser_download_url: 'https://github.com/guweigang/vhttpd/releases/download/${tag}/${name}'
		}]
	}
}

fn test_desktop_update_compares_asset_version_and_filters_platform() ! {
	draft := update_fixture_release('desktop-v4.0.0', '4.0.0', 'macos-arm64')
	preview := update_fixture_release('desktop-v3.0.0-rc.1', '3.0.0-rc.1', 'macos-arm64')
	releases := [
		RuntimeRelease{...draft, draft: true},
		RuntimeRelease{...preview, prerelease: true},
		update_fixture_release('desktop-v2.0.0', '2.0.0', 'windows-amd64'),
		update_fixture_release('v8.0.0', '0.1.9', 'macos-arm64'),
		update_fixture_release('desktop-v0.1.10', '0.1.10', 'macos-arm64'),
	]
	update := newest_desktop_update(releases, '0.1.9-dev.g123', 'macos-arm64')!
	assert update.version == '0.1.10'
	assert update.url == desktop_release_page + 'desktop-v0.1.10'
	assert newest_desktop_update(releases, '0.1.10', 'macos-arm64')!.url == ''
	assert newest_desktop_update(releases, '1.0.0', 'windows-amd64')!.version == '2.0.0'
	assert newest_desktop_update(releases, '0.1.0', 'linux-amd64')!.url == ''
}

fn test_desktop_update_accepts_stable_over_same_base_preview() ! {
	releases := [update_fixture_release('v0.9.0', '0.1.0', 'linux-arm64')]
	update := newest_desktop_update(releases, '0.1.0-dev.g123', 'linux-arm64')!
	assert update.version == '0.1.0'
	assert update.url == desktop_release_page + 'v0.9.0'
}
