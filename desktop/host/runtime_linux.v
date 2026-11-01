module host

import crypto.rand
import crypto.sha256
import os

fn install_linux_runtime(archive string, expected string, tag string, job RuntimeJob) !string {
	if expected.len != 64 || !expected.bytes().all(it.is_hex_digit()) {
		return error('缺少有效的 SHA256 校验值。')
	}
	// Keep the downloader's same immutable-package and checksum boundary.
	platform := local_runtime_platform()
	validate_remote_archive(archive, platform, job)!
	listing := job.command('/usr/bin/tar', ['-tvzf', archive], 15000)!
	rows := listing.split_into_lines()
	if rows.len > 20000 { return error('运行包文件数量超出限制。') }
	mut unpacked := i64(0)
	for row in rows {
		fields := row.fields()
		if fields.len < 3 || !fields[2].bytes().all(it.is_digit()) {
			return error('无法检查运行包解压大小。')
		}
		size := fields[2].i64()
		if size < 0 || size > 536870912 { return error('运行包解压大小超出限制。') }
		unpacked += size
		if unpacked > 536870912 { return error('运行包解压大小超出限制。') }
	}

	if sha256.sum(os.read_bytes(archive)!).hex() != expected.to_lower() {
		return error('SHA256 不一致，运行包未安装。')
	}
	root := os.join_path(workbench_data_dir(), 'runtimes')
	os.mkdir_all(root)!
	stage := os.join_path(root, '.install-' + rand.bytes(12)!.hex())
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	job.command('/usr/bin/tar', ['-xzf', archive, '-C', stage, '--no-same-owner',
		'--no-same-permissions'], 60000)!
	source := os.join_path(stage, 'vhttpd-' + platform)
	binary := os.join_path(source, 'vhttpd')
	header := os.read_bytes(binary)!
	machine := if platform == 'linux-arm64' { 183 } else { 62 }
	if header.len < 20 || header[..4] != [u8(0x7f), `E`, `L`, `F`] || header[4] != 2 || header[5] != 1 || int(header[18]) + int(header[19]) * 256 != machine {
		return error('运行包 ELF 架构不匹配。')
	}
	info := inspect_runtime(binary, '', job)
	if !info.ready { return error(info.message) }
	job.command(binary, ['--help'], 10000)!
	if tag != '' {
		write_project_contents(create_project_file(source + '/.release-tag')!, normalize_runtime_tag(tag)!)!
	}
	final := os.join_path(root, 'vhttpd-' + info.version + '-' + rand.bytes(6)!.hex())
	os.mv(source, final)!
	installed := os.join_path(final, 'vhttpd')
	save_runtime_selection(installed) or {
		os.rmdir_all(final) or {}
		return err
	}
	return installed
}

pub fn linux_archive_checksum(path string) !string {
	return checksum_for(os.read_file(path + '.sha256')!, os.file_name(path))
}
