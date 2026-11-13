module host

import json2 as json
import net.urllib
import os
import semver

const desktop_releases_api = 'https://api.github.com/repos/guweigang/vhttpd/releases'
const desktop_release_page = 'https://github.com/guweigang/vhttpd/releases/tag/'

pub struct DesktopUpdate {
pub:
	version string
	url     string
}

pub fn check_desktop_update(current string, job RuntimeJob) !DesktopUpdate {
	platform := local_runtime_platform()
	if platform == '' { return error('当前平台没有可检查的 Desktop 下载包。') }
	curl := runtime_curl()
	if !os.is_file(curl) { return error('系统缺少 curl，无法检查更新。') }

	mut best := DesktopUpdate{version: current}
	for page := 1; ; page++ {
		raw := job.command(curl, ['--disable', '--fail', '--silent', '--show-error',
			'--proto', '=https', '--connect-timeout', '5', '--max-time', '10',
			'--max-filesize', '4194304', '--header', 'Accept: application/vnd.github+json',
			'${desktop_releases_api}?per_page=50&page=${page}'], 11000) or {
			return error('无法检查更新。请检查网络后重试。')
		}
		releases := json.decode[[]RuntimeRelease](raw) or {
			return error('无法读取 GitHub 发布信息，请稍后重试。')
		}
		candidate := newest_desktop_update(releases, best.version, platform)!
		if candidate.url != '' { best = candidate }
		if releases.len < 50 { break }
	}
	return if best.url == '' { DesktopUpdate{} } else { best }
}

fn newest_desktop_update(releases []RuntimeRelease, current string, platform string) !DesktopUpdate {
	mut best := semver.from(current)!
	mut update := DesktopUpdate{}
	prefix := 'vhttpd-workbench-${platform}-'
	suffix := if platform.starts_with('linux-') { '.tar.gz' } else { '.zip' }
	for release in releases {
		if release.draft || release.prerelease { continue }
		tag := release.tag_name
		desktop_tag := tag.starts_with('desktop-v')
		if !desktop_tag && !tag.starts_with('v') { continue }
		tag_version := if desktop_tag { tag['desktop-v'.len..] } else { tag[1..] }
		parsed_tag := semver.from(tag_version) or { continue }
		if parsed_tag.prerelease != '' || parsed_tag.str() != tag_version { continue }
		for asset in release.assets {
			if asset.size <= 0 || !asset.name.starts_with(prefix) || !asset.name.ends_with(suffix)
				|| !official_asset_url(asset.browser_download_url) { continue }
			version := asset.name[prefix.len..asset.name.len - suffix.len]
			if desktop_tag && version != tag_version { continue }
			candidate := semver.from(version) or { continue }
			if candidate.prerelease != '' || candidate.str() != version || candidate <= best { continue }
			best = candidate
			update = DesktopUpdate{version: version, url: desktop_release_page + urllib.path_escape(tag)}
		}
	}
	return update
}
