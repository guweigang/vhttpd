module host

import crypto.rand
import crypto.sha256
import encoding.binary
import os

fn windows_runtime_tool(name string) string {
	return os.join_path(os.getenv_opt('WINDIR') or { 'C:\\Windows' }, 'System32', name)
}

fn validate_windows_runtime_listing(names string, details string, prefix string) ! {
	paths := names.split_into_lines()
	rows := details.split_into_lines()
	if paths.len == 0 || paths.len > 20000 || paths.len != rows.len {
		return error('运行包目录无效。')
	}
	mut seen := map[string]bool{}
	mut total := u64(0)
	for i, path in paths {
		name := path.trim_string_right('/')
		parts := name.split('/')
		key := name.to_lower()
		if path.len > 4096 || parts[0] != prefix || key in seen
			|| parts.any(!windows_runtime_path_part(it)) {
			return error('运行包包含不安全的路径。')
		}
		seen[key] = true
		// Windows tar.exe is bsdtar. Its verbose listing places size after
		// mode, link count, owner and group. Only files and directories are accepted.
		fields := rows[i].fields()
		if fields.len < 6 || fields[0].len == 0 || fields[0][0] !in [`-`, `d`]
			|| !fields[4].bytes().all(it.is_digit()) || fields[4].len > 10 || !rows[i].ends_with(' ' + path) {
			return error('运行包包含不支持的文件类型或大小。')
		}
		total += fields[4].u64()
		if total > 536870912 { return error('运行包解压大小超出限制。') }
	}
}

fn windows_runtime_path_part(part string) bool {
	if part == '' || part.ends_with('.') || part.ends_with(' ')
		|| part.bytes().any(it < 32 || it == 127 || it in [`\\`, `:`, `"`, `<`, `>`, `|`, `?`, `*`]) {
		return false
	}
	base := part.all_before('.').trim_space().to_upper()
	return base !in ['CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$']
		&& base !in ['COM0', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
			'LPT0', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
			'COM¹', 'COM²', 'COM³', 'LPT¹', 'LPT²', 'LPT³']
}

fn install_windows_runtime(archive string, expected string, tag string, job RuntimeJob, select_package bool) !string {
	if expected.len != 64 || !expected.bytes().all(it.is_hex_digit()) {
		return error('缺少有效的 SHA256 校验值。')
	}
	if !os.is_file(archive) || os.file_size(archive) > 268435456 {
		return error('下载文件大小无效。')
	}
	job.stage('正在校验 SHA256…')
	if sha256.sum(os.read_bytes(archive)!).hex() != expected.to_lower() {
		return error('SHA256 不一致，运行包未安装。')
	}
	job.stage('正在检查并解压运行包…')
	prefix := 'vhttpd-windows-amd64'
	tar := windows_runtime_tool('tar.exe')
	names := job.command(tar, ['-tf', archive], 30000)!
	details := job.command(tar, ['-tvf', archive], 30000)!
	validate_windows_runtime_listing(names, details, prefix)!
	root := os.join_path(workbench_data_dir(), 'runtimes')
	os.mkdir_all(root)!
	stage := os.join_path(root, '.install-' + rand.bytes(12)!.hex())
	os.mkdir(stage)!
	defer { os.rmdir_all(stage) or {} }
	job.command(tar, ['-xf', archive, '-C', stage], 60000)!
	source := os.join_path(stage, prefix)
	executable := os.join_path(source, runtime_executable_name())
	if !os.is_file(executable) || !os.is_file(os.join_path(source, 'admin', 'ui', 'index.html')) {
		return error('运行包不完整，需要 vhttpd.exe 和 Admin UI。')
	}
	image := os.read_bytes(executable)!
	offset := if image.len >= 64 { int(binary.little_endian_u32(image[60..64])) } else { -1 }
	if offset < 64 || offset > image.len - 26 || image[..2] != [u8(`M`), `Z`]
		|| image[offset..offset + 6] != [u8(`P`), `E`, 0, 0, 0x64, 0x86]
		|| binary.little_endian_u16(image[offset + 24..offset + 26]) != 0x20b {
		return error('运行包 PE 架构不匹配。')
	}
	job.stage('正在检查架构、动态库和程序版本…')
	info := inspect_runtime(executable, '', job)
	if !info.ready { return error(info.message) }
	job.command(executable, ['--help'], 10000)!
	return publish_runtime_package(source, info.version, tag, select_package)
}
