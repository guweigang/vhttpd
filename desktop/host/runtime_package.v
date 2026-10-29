module host

import crypto.rand
import json2 as json
import os
import time

pub struct RuntimeInfo {
pub:
	path    string
	version string
	source  string
	ready   bool
	message string
}

pub struct RuntimeJob {
pub:
	cancel   chan bool   = chan bool{cap: 1}
	progress chan string = chan string{cap: 16}
}

struct RuntimeSelection {
	path string
}

struct RuntimeReleaseAsset {
	name                 string
	size                 i64
	browser_download_url string
}

struct RuntimeRelease {
	published_at string
	tag_name   string
	draft      bool
	prerelease bool
	assets     []RuntimeReleaseAsset
}

pub fn selected_runtime(executable string, development_root string) !string {
	if value := os.getenv_opt('VHTTPD_DESKTOP_BINARY') { return value }
	path := os.join_path(workbench_data_dir(), 'runtime-selection.json')
	if os.exists(path) {
		if os.is_link(path) || os.file_size(path) > 16384 {
			return error('运行包选择记录无效，请重新选择。')
		}
		selection := json.decode[RuntimeSelection](os.read_file(path)!) or { return error('运行包选择记录无法读取，请重新选择。') }
		if selection.path != '' { return selection.path }
	}
	return workbench_binary(executable, development_root)
}

pub fn save_runtime_selection(path string) ! {
	if !os.is_abs_path(path) || !os.is_executable(path) {
		return error('请选择可执行的 vhttpd。')
	}
	os.mkdir_all(workbench_data_dir())!
	target := os.join_path(workbench_data_dir(), 'runtime-selection.json')
	if os.is_link(target) { return error('运行包选择记录不能是符号链接。') }
	temp := target + '.' + rand.bytes(8)!.hex()
	defer { os.rm(temp) or {} }
	fd := create_project_file(temp)!
	write_project_contents(fd, json.encode(RuntimeSelection{ path: path }))!
	os.mv(temp, target)!
}

fn (job RuntimeJob) command(executable string, args []string, limit_ms i64) !string {
 return job.command_with_environment(executable, args, limit_ms, map[string]string{})
}

fn (job RuntimeJob) command_with_environment(executable string, args []string, limit_ms i64, environment map[string]string) !string {
	mut child := os.new_process(executable)
	child.set_args(args)
 if environment.len > 0 { child.set_environment(environment) }
 $if windows { child.create_no_window = true; if 'VHTTPD_SSH_ASKPASS_SOCKET' in environment { child.set_work_folder(os.dir(os.executable())) } }
	child.set_redirect_stdio_merged()
	child.use_pgroup = true
	child.run()
	defer { child.close() }
	deadline := time.ticks() + limit_ms
	mut output := ''
	for {
		select {
			_ := <-job.cancel {
				child.signal_pgkill()
				child.signal_kill()
				child.wait()
				return error('操作已取消。')
			}
			else {
			}
		}
		// Drain before waiting: unzip can produce more than a pipe buffer.
		for _ in 0 .. 16 {
			if !child.is_pending(.stdout) { break }
			output += child.stdout_read()
			if output.len > 4194304 {
				child.signal_pgkill()
				child.signal_kill()
				child.wait()
				return error('工具输出过大。')
			}
		}
		if !child.is_alive() { break }
		if time.ticks() >= deadline {
			child.signal_pgkill()
			child.signal_kill()
			child.wait()
			return error('操作超时，请重试。')
		}
		time.sleep(10 * time.millisecond)
	}
	child.wait()
	for child.is_pending(.stdout) {
		part := child.stdout_read()
		if part == '' { break }
		output += part
		if output.len > 4194304 { return error('工具输出过大。') }
	}
	if child.code != 0 {
		return error(os.file_name(executable) + ' 执行失败（退出码 ' + child.code.str() + '）。')
	}
	return output.trim_space()
}

fn runtime_version_text(value string) !string {
	version := value.trim_space().trim_string_left('vhttpd ').trim_string_left('v')
	parts := version.all_before('-').all_before('+').split('.')
	if version.len > 100 || version.contains('\n') || parts.len != 3 || !parts.all(it != '' && it.bytes().all(it.is_digit())) || !version.bytes().all(it.is_letter() || it.is_digit() || it in [
		`.`,
		`-`,
		`+`,
	]) {
		return error('无法识别 vhttpd --version 的输出。')
	}
	return version
}

pub fn inspect_runtime(path string, executable string, job RuntimeJob) RuntimeInfo {
	bundled := os.real_path(bundled_workbench_binary(executable))
	mut source := if os.real_path(path) == bundled {
		'App 内置'
	} else if os.real_path(path).starts_with(os.real_path(os.join_path(workbench_data_dir(), 'runtimes')) + os.path_separator) {
		'已下载'
	} else {
		'本地选择'
	}
	marker := os.join_path(os.dir(path), '.release-tag')
	if os.is_file(marker) && !os.is_link(marker) && os.file_size(marker) < 256 {
		if tag := normalize_runtime_tag(os.read_file(marker) or { '' }) { source += ' · ' + tag }
	}
	if !os.is_executable(path) {
		return RuntimeInfo{ path: path, source: source, message: '未找到可用运行包。可下载官方完整运行包，或选择本地 vhttpd。' }
	}
	raw := job.command(path, ['--version'], 5000) or { return RuntimeInfo{ path: path, source: source, message: '运行包无法执行或读取版本失败，请重新选择或下载。' } }
	version := runtime_version_text(raw) or { return RuntimeInfo{ path: path, source: source, message: err.msg() } }
	return RuntimeInfo{ path: path, version: version, source: source, ready: true, message: '可启动项目；版本来自此运行程序的 --version。' }
}

fn (job RuntimeJob) stage(value string) {
	select {
		job.progress <- value {
		}
		else {
		}
	}
}

fn official_asset_url(value string) bool {
	return value.starts_with('https://github.com/guweigang/vhttpd/releases/download/') && !value.contains('?') && !value.contains('#') && !value.bytes().any(it < 33 || it == 127)
}

fn (job RuntimeJob) fetch(url string, path string, max_size i64) ! {
	job.command('/usr/bin/curl', ['--fail', '--silent', '--show-error', '--location', '--proto',
		'=https', '--proto-redir', '=https', '--connect-timeout', '15', '--max-time', '180',
		'--max-filesize', max_size.str(), '--output', path, url], 185000)!
	if !os.is_file(path) || os.file_size(path) > u64(max_size) {
		return error('下载文件大小无效。')
	}
}

fn runtime_assets(release RuntimeRelease) !(RuntimeReleaseAsset, RuntimeReleaseAsset) {
	return runtime_assets_for(release, false)
}

fn runtime_assets_for(release RuntimeRelease, allow_preview bool) !(RuntimeReleaseAsset, RuntimeReleaseAsset) {
	if release.draft || (release.prerelease && !allow_preview) || !release.tag_name.starts_with('v') {
		return error('尚无可用的正式运行包。')
	}
	version := runtime_version_text(release.tag_name)!
	name := 'vhttpd-workbench-macos-arm64-${version}.zip'
	checks := 'vhttpd-workbench-macos-arm64-${version}-SHA256SUMS.txt'
	mut archive := RuntimeReleaseAsset{}
	mut sums := RuntimeReleaseAsset{}
	for asset in release.assets {
		if asset.name == name { archive = asset }
		if asset.name == checks { sums = asset }
	}
	if archive.size < 1 || archive.size > 268435456 || sums.size < 1 || sums.size > 1048576 || !official_asset_url(archive.browser_download_url) || !official_asset_url(sums.browser_download_url) {
		return error('该版本尚未提供完整的 Apple Silicon Mac 运行包及 SHA256 校验文件。')
	}
	return archive, sums
}

fn checksum_for(text string, filename string) !string {
	mut found := ''
	for line in text.split_into_lines() {
		fields := line.fields()
		if fields.len == 2 && fields[1].trim_string_left('*') == filename {
			if found != '' || fields[0].len != 64 || !fields[0].bytes().all(it.is_hex_digit()) {
				return error('校验文件格式无效。')
			}
			found = fields[0].to_lower()
		}
	}
	if found == '' { return error('校验文件中没有对应的下载包。') }
	return found
}

pub fn download_runtime(job RuntimeJob) !string {
	return download_runtime_release('', job)
}

pub fn download_runtime_release(tag string, job RuntimeJob) !string {
	platform := local_runtime_platform()
	if platform == '' { return error('此系统暂无完整官方运行包。') }
	root := os.join_path(workbench_data_dir(), 'runtimes')
	os.mkdir_all(root)!
	temp := os.join_path(root, '.download-' + rand.bytes(12)!.hex())
	os.mkdir(temp)!
	os.chmod(temp, 0o700)!
	defer { os.rmdir_all(temp) or {} }
	choice := resolve_runtime_download(platform, tag, job)!
	zip := download_runtime_files(choice, temp, job)!
	expected := checksum_for(os.read_file(zip + '.sha256')!, choice.archive.name)!
	return install_runtime_archive_tag(zip, expected, choice.tag, job)
}

fn validate_archive_listing(names string, details string) ! {
	paths := names.split_into_lines()
	if paths.len == 0 || paths.len > 20000 { return error('运行包目录无效。') }
	mut seen := map[string]bool{}
	for path in paths {
		if path == '' || path.len > 4096 || path.starts_with('/') || path.contains('\\') || path.split('/').contains('..') || path.bytes().any(it < 32 || it == 127) || path in seen {
			return error('运行包包含不安全的路径。')
		}
		seen[path] = true
	}
	mut total := i64(0)
	for line in details.split_into_lines() {
		if line.starts_with('l') { return error('运行包不接受符号链接。') }
		if line.starts_with('-') {
			fields := line.fields()
			if fields.len < 4 { return error('无法检查运行包大小。') }
			size := fields[3].i64()
			if size < 0 { return error('运行包大小无效。') }
			total += size
		}
	}
	if total <= 0 || total > 536870912 { return error('运行包解压大小超出限制。') }
}

// Shared by the downloader and the installed-app regression. Selection is
// committed only after every check succeeds; prior packages remain untouched.
pub fn install_runtime_archive(archive string, expected string, job RuntimeJob) !string {
	return install_runtime_archive_tag(archive, expected, '', job)
}

fn install_runtime_archive_tag(archive string, expected string, tag string, job RuntimeJob) !string {
	$if linux { return install_linux_runtime(archive, expected, tag, job) }
	if expected.len != 64 || !expected.bytes().all(it.is_hex_digit()) {
		return error('缺少有效的 SHA256 校验值。')
	}
	job.stage('正在校验 SHA256…')
	actual := job.command('/usr/bin/shasum', ['-a', '256', archive], 30000)!
	if actual.fields()[0].to_lower() != expected.to_lower() {
		return error('SHA256 不一致，下载包未安装；请重新下载。')
	}
	job.stage('正在检查并解压运行包…')
	names := job.command('/usr/bin/unzip', ['-Z1', archive], 30000)!
	details := job.command('/usr/bin/unzip', ['-Z', '-l', archive], 30000)!
	validate_archive_listing(names, details)!
	root := os.join_path(workbench_data_dir(), 'runtimes')
	os.mkdir_all(root)!
	stage := os.join_path(root, '.install-' + rand.bytes(12)!.hex())
	os.mkdir(stage)!
	os.chmod(stage, 0o700)!
	defer { os.rmdir_all(stage) or {} }
	job.command('/usr/bin/ditto', ['-x', '-k', archive, stage], 60000)!
	source := os.join_path(stage, 'vhttpd-workbench.app', 'Contents', 'Resources', 'runtime')
	binary := os.join_path(source, 'vhttpd')
	if !os.is_executable(binary) || !os.is_file(os.join_path(source, 'admin', 'ui', 'index.html')) || !os.is_dir(os.join_path(source, 'lib')) {
		return error('运行包不完整，需要 vhttpd、Admin UI 和动态库。')
	}
	job.stage('正在检查架构、动态库和程序版本…')
	mut binaries := [binary]
	binaries << os.walk_ext(os.join_path(source, 'lib'), '.dylib')
	for item in binaries {
		macho := inspect_runtime_macho(os.read_bytes(item)!)!
		if item == binary && macho.filetype != 2 {
			return error('运行程序不是 Mach-O 可执行文件。')
		}
		job.command('/usr/bin/codesign', ['--verify', '--strict', item], 10000) or { return error('运行包代码签名校验失败。') }
		for dependency in macho.dependencies {
			if dependency.starts_with('/usr/lib/') || dependency.starts_with('/System/Library/') {
				continue
			}
			if !dependency.starts_with('@loader_path/') {
				return error('运行包仍依赖开发环境中的动态库。')
			}
			target := os.real_path(os.join_path(os.dir(item), dependency.all_after('@loader_path/')))
			if !target.starts_with(os.real_path(source) + os.path_separator) || !os.is_file(target) {
				return error('运行包动态库缺失或越界。')
			}
		}
	}
	info := inspect_runtime(binary, '', job)
	if !info.ready { return error(info.message) }
	job.command(binary, ['--help'], 10000)!
	if tag != '' { write_project_contents(create_project_file(os.join_path(source, '.release-tag'))!, normalize_runtime_tag(tag)!)! }
	final := os.join_path(root, 'vhttpd-' + info.version + '-' + rand.bytes(6)!.hex())
	os.mv(source, final)!
	installed := os.join_path(final, 'vhttpd')
	save_runtime_selection(installed) or {
		os.rmdir_all(final) or {}
		return err
	}
	return installed
}
