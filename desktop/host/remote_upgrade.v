module host

import encoding.base64
import json2 as json
import os
import runtime_upgrade
import time

pub type RemoteRuntimeUpgrade = runtime_upgrade.Status

pub fn upgrade_phase_title(status RemoteRuntimeUpgrade) string {
	return match status.phase {
		'queued', 'validating' { '正在校验升级条件' }
		'stopping' { '正在停止原版本' }
		'starting' { '正在启动目标版本并检查生效' }
		'rolling_back' { '升级未完成，正在恢复原版本' }
		'completed' { '升级成功 · 整项目已生效' }
		'rolled_back' { '升级失败 · 原版本已恢复' }
		'rollback_failed' { '恢复未完成 · 需要处理' }
		'failed' { '升级未完成 · 请检查实例' }
		else { '升级状态待确认' }
	}
}

pub fn upgrade_error_hint(status RemoteRuntimeUpgrade) string {
	return match status.error {
		'' { '' }
		'instance_not_effective', 'project_changed_validate_again', 'project_changed_during_upgrade' {
			'配置有待生效修改或在升级中变化，请先完成整项目发布和生效检查。'
		}
		'whole_project_validation_failed' {
			'目标版本无法通过整项目校验，未切换运行包。'
		}
		'process_identity_unavailable' {
			'系统无法提供安全的进程身份控制，实例未停止；请检查 Linux 内核和进程权限。'
		}
		'old_process_still_alive', 'target_process_still_alive' {
			'进程未在期限内退出，已停止后续切换；请检查运行日志。'
		}
		'new_process_exited', 'startup_or_effectiveness_timeout', 'runtime_version_mismatch' {
			'目标版本启动或生效检查失败，请查看升级运行日志。'
		}
		'runtime_binding_restore_failed' {
			'原进程已恢复，但版本绑定未能保存；请检查服务器磁盘和权限后处理。'
		}
		'previous_version_not_effective', 'previous_process_failed' {
			'原版本未恢复就绪，请检查配置、端口和升级运行日志后处理。'
		}
		else {
			'实例或运行包状态已变化，请刷新后检查；诊断日志不展示凭据。'
		}
	}
}

fn (mut s ServerSession) upgrade(command ServerCommand) ! {
	s.inspect()!
	if s.state.upgrades.any(!it.finished()) || s.state.deployments.any(!it.finished()) {
		return error('该服务器有升级正在进行，请等待完成或重连查看结果。')
	}
	matches := s.state.projects.filter(it.id == command.project_id)
	if matches.len != 1 { return error('项目已变化，请刷新后重新选择。') }
	profile := matches[0]
	if profile.config_path != os.join_path(s.state.root, 'instances', profile.name, 'vhttpd.toml') || profile.runtime_id == '' {
		return error('仅支持工作台管理且已绑定运行包的手工实例。')
	}
	target := select_remote_runtime(s.state.runtimes, command.runtime_id)!
	if target.id == profile.runtime_id { return error('该实例已使用所选运行包。') }
	mut manager := &RemoteManager{}
	manager.connect_with_session(profile, '', s.state.control_path)!
	defer {
		manager.disconnect()
		for endpoint in manager.browser_endpoints {
			mut server := endpoint.server
			server.stop()
		}
	}
	instance := json.decode[RemoteInstance](manager.request(.get, '/admin/workbench/instance', '')!.body)!
	if !instance.ready || !instance.manual_restart || instance.disk_revision == '' || instance.disk_revision != instance.effective_revision || instance.config_path != profile.config_path {
		return error('请先让实例业务就绪、完成待生效配置，再升级运行包。')
	}
	// This command is implemented by the target binary, so validation uses its parser.
	output := s.shell(shell_quote(target.path + '/vhttpd') + ' --workbench-upgrade-check ' + shell_quote(profile.config_path), 15000) or { return error('目标包未通过整项目校验或不支持安全升级，请使用支持升级协议的新版官方包。原实例未停止。') }
	check := json.decode[runtime_upgrade.Check](output.trim_space()) or { return error('目标包未提供安全升级协议，原实例未停止。') }
	if check.protocol != 1 || check.version != target.version || check.revision != instance.effective_revision {
		return error('项目在校验期间已变化，请刷新后重试。原实例未停止。')
	}
	id := new_remote_id()!
	request := runtime_upgrade.Request{ id: id, server_root: s.state.root, config_path: profile.config_path, previous_version: instance.version, target_version: check.version, previous_id: profile.runtime_id, target_id: target.id, admin_port: profile.admin_port, token: profile.token, expected_boot: instance.boot_id, expected_revision: instance.effective_revision }
	queued := RemoteRuntimeUpgrade{ id: id, config_path: profile.config_path, previous_id: profile.runtime_id, target_id: target.id, phase: 'queued' }
	script := 'set -eu\numask 077\nproject=' + shell_quote(os.dir(profile.config_path)) + '\nid=' + shell_quote(id) + '\nrequest=' + shell_quote(base64.encode_str(json.encode(request))) + '\nstatus=' + shell_quote(base64.encode_str(json.encode(queued))) + '\nbinary=' + shell_quote(target.path + '/vhttpd') + '\n' + $embed_file('remote_scripts/upgrade.sh').to_string()
	s.shell(script, 8000)!
	mut statuses := s.state.upgrades.filter(it.config_path != profile.config_path)
	statuses << queued
	s.state = ServerSnapshot{ ...s.state, upgrades: statuses, message: '升级已交由远端执行。断开 SSH 或退出工作台后，仍会继续检查和失败回退。' }
}

fn (mut s ServerSession) poll_upgrades() ! {
	mut statuses := []RemoteRuntimeUpgrade{}
	for prior in s.state.upgrades {
		if prior.finished() {
			statuses << prior
			continue
		}
		path := os.join_path(os.dir(prior.config_path), '.desktop-upgrades', prior.id, 'status.json')
		text := s.shell('set -eu\np=' + shell_quote(path) + '\n[ ! -L "$p" ] && [ -f "$p" ] && [ "$(wc -c < "$p")" -le 16384 ]\nbase64 < "$p"', 6000)!
		status := json.decode[RemoteRuntimeUpgrade](base64.decode_str(text.replace('\n', '')))!
		if status.id != prior.id || status.config_path != prior.config_path {
			return error('升级状态不匹配，请重新连接服务器。')
		}
		statuses << status
	}
	mut completed := false
	for status in statuses {
		for prior in s.state.upgrades {
			if status.id == prior.id && status.finished() && !prior.finished() { completed = true }
		}
	}
	s.state = ServerSnapshot{ ...s.state, upgrades: statuses }
	if completed { s.discover_projects()! }
	s.next_upgrade_probe = time.ticks() + 1500
}
