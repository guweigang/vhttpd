module host

import config
import os

// Starting a stopped process must use SSH, since its Admin API is unavailable.
fn (mut s ServerSession) start_project(command ServerCommand) ! {
	s.inspect()!
	if s.state.upgrades.any(!it.finished()) || s.state.deployments.any(!it.finished()) {
		return error('远端有升级或部署尚未完成，请先检查操作状态。')
	}
	matches := s.state.projects.filter(it.id == command.project_id)
	if matches.len != 1 { return error('请选择服务器上已登记的实例。') }
	p := matches[0]
	if p.config_path != os.join_path(s.state.root, 'instances', p.name, 'vhttpd.toml') || p.runtime_id == '' {
		return error('仅支持启动工作台管理且已绑定运行包的实例。')
	}
	runtime := select_remote_runtime(s.state.runtimes, p.runtime_id)!
	mut sources := map[string]string{}
	mut visiting := map[string]bool{}
	s.read_project_sources(p.config_path, mut sources, mut visiting) or { return error('无法读取远端实例配置，请检查文件和 include。') }
	plan := config.load_runtime_plan_with_overrides(p.config_path, sources) or { return error('远端实例配置无效，请修复后再启动。') }
	project := os.dir(p.config_path)
	pid_path := if plan.server.pid_file == '' { '' } else { remote_absolute_path(project, plan.server.pid_file)! }
	if pid_path != '' && !pid_path.starts_with(project + '/') {
		return error('PID 文件需位于实例目录内，才能安全恢复停止的实例。')
	}
	script := 'set -eu\numask 077\nproject=' + shell_quote(project) + '\nconfig=' + shell_quote(p.config_path) + '\nbinary=' + shell_quote(runtime.path + '/vhttpd') + '\nruntime_id=' + shell_quote(runtime.id) + '\ninstance_id=' + shell_quote(p.id) + '\npid_file=' + shell_quote(pid_path) + '\n' + $embed_file('remote_scripts/start.sh').to_string()
	s.shell(script, 20000)!
	s.discover_projects()!
	s.state = ServerSnapshot{ ...s.state, error: false, created: p, message: '已有实例已启动，正在连接并检查业务就绪。' }
}
