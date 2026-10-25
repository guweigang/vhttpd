module host

import json2 as json
import net.urllib
import os

pub struct RuntimeDownload {
pub:
	tag string
	channel string
	published_at string
	platform string
	archive RuntimeReleaseAsset
	checksums RuntimeReleaseAsset
}

pub fn normalize_runtime_tag(value string) !string {
	mut tag := value.trim_space()
	if tag.starts_with('https://github.com/guweigang/vhttpd/releases/tag/') {
		tag = urllib.path_unescape(tag.all_after('/releases/tag/').all_before('?').all_before('#')) or { return error('Release 链接编码无效。') }
	}
	if !tag.starts_with('v') { tag = 'v' + tag }
	runtime_version_text(tag) or { return error('请填写有效版本号（如 v1.2.3 或 v0.1.0-dev.g提交号），或官方 Release 链接。') }
	return tag
}

fn runtime_download_for(release RuntimeRelease, platform string) !RuntimeDownload {
	if release.draft { return error('草稿版本尚未公开。') }
	tag := normalize_runtime_tag(release.tag_name)!
	mut archive := RuntimeReleaseAsset{}
	mut checks := RuntimeReleaseAsset{}
	if platform == 'macos-arm64' {
		archive, checks = runtime_assets_for(release, true)!
	} else if platform in ['linux-amd64', 'linux-arm64'] {
		for item in release.assets {
			if item.name == 'vhttpd-${platform}.tar.gz' { archive = item }
			if item.name == 'vhttpd-${platform}.tar.gz.sha256' { checks = item }
		}
	} else { return error('不支持该运行平台。') }
	if archive.size < 1 || archive.size > 268435456 || checks.size < 1 || checks.size > 1048576 || !official_asset_url(archive.browser_download_url) || !official_asset_url(checks.browser_download_url) {
		return error('该版本尚无此平台的完整运行包及 SHA256 校验文件。')
	}
	return RuntimeDownload{tag: tag, channel: if release.prerelease { 'development' } else { 'stable' }, published_at: release.published_at, platform: platform, archive: archive, checksums: checks}
}

// Metadata and downloads are public GitHub endpoints. No GitHub credential is
// requested, read from the user's environment, or passed to external tools.
pub fn runtime_catalog(platform string, channel string, specified string, job RuntimeJob) ![]RuntimeDownload {
	if channel !in ['all', 'stable', 'development'] { return error('版本渠道无效。') }
	temp := os.join_path(os.temp_dir(), 'vh-catalog-' + new_remote_id()!)
	os.mkdir(temp, mode: 0o700)!
	defer { os.rmdir_all(temp) or {} }
	path := temp + '/releases.json'
	url := if specified.trim_space() != '' {
		'https://api.github.com/repos/guweigang/vhttpd/releases/tags/' + normalize_runtime_tag(specified)!
	} else { 'https://api.github.com/repos/guweigang/vhttpd/releases?per_page=30' }
	job.fetch(url, path, 4194304) or {
		if err.msg() == '操作已取消。' { return err }
		return error('无法读取公开版本。请检查网络、版本号或 GitHub API 限流后重试。')
	}
	if specified.trim_space() != '' {
		release := json.decode[RuntimeRelease](os.read_file(path)!)!
		return [runtime_download_for(release, platform)!]
	}
	releases := json.decode[[]RuntimeRelease](os.read_file(path)!)!
	mut choices := []RuntimeDownload{}
	for release in releases {
		choice := runtime_download_for(release, platform) or { continue }
		if channel == 'all' || channel == choice.channel { choices << choice }
	}
	return choices
}

fn resolve_runtime_download(platform string, tag string, job RuntimeJob) !RuntimeDownload {
	if tag != '' {
		choices := runtime_catalog(platform, 'all', tag, job)!
		return choices[0]
	}
	temp := os.join_path(os.temp_dir(), 'vh-release-' + new_remote_id()!)
	os.mkdir(temp, mode: 0o700)!
	defer { os.rmdir_all(temp) or {} }
	job.fetch('https://api.github.com/repos/guweigang/vhttpd/releases/latest', temp + '/release.json', 4194304)!
	release := json.decode[RuntimeRelease](os.read_file(temp + '/release.json')!)!
	if release.prerelease { return error('最新稳定版本信息无效。') }
	return runtime_download_for(release, platform)!
}

fn download_runtime_files(choice RuntimeDownload, directory string, job RuntimeJob) !string {
	job.stage('正在下载 ${choice.tag} · ${choice.platform}…')
	archive := os.join_path(directory, choice.archive.name)
	job.fetch(choice.archive.browser_download_url, archive, 268435456)!
	job.fetch(choice.checksums.browser_download_url, archive + '.sha256', 1048576)!
	checksum_for(os.read_file(archive + '.sha256')!, choice.archive.name)!
	return archive
}
