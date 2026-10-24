module main

import host
import ui2

fn (mut app Workshop) inspect_current_project() {
	if app.projects.len == 0 || app.new_project { return }
	app.details_error = ''
	app.details = host.project_details(app.projects[app.selected]) or {
		app.details_error = '配置解析失败，请在编辑器中修复配置后重新读取。'
		host.ProjectDetails{}
	}
	app.show_details = true
}

fn project_details_view(app &Workshop, width f64) []ui2.Element {
	project := app.projects[app.selected]
	mut elements := [
		label('details_breadcrumb', '本地项目  /  ${project.name}', 0, 25, width, 12, workbench_muted),
		label('details_title', '项目配置 / Relay', 0, 73, width, 25, workbench_ink),
		label('details_intro', '以下来自磁盘配置；连接、重连与通道状态请查看 Admin UI → Relay。', 0, 111, width, 12, workbench_muted),
		button('details_close', '返回工作台', 0, 157, 100, false, true),
		button('details_refresh', '重新读取', 112, 157, 90, false, true),
		button('edit_config', '打开配置', 214, 157, 90, false, true),
		button('edit_source', '打开源码', 316, 157, 90, false, app.details.entry != ''),
		button('admin', 'Admin UI ↗', 418, 157, 115, true, app.snapshot.phase == .running),
	]
	mut lines := ['项目：${project.name}', '配置文件：${project.config_path}',
		'工作目录：${project.workdir}', '', '监听器']
	lines << app.details.listeners
	lines << ['', '源码入口']
	lines << if app.details.sources.len == 0 {
		['未声明源码入口。']
	} else {
		app.details.sources
	}
	lines << ['', 'Relay 配置（项目级）',
		'agent 主动连接 hub；local / remote 表示部署位置，不是运行角色。']
	if app.details.relays.len == 0 {
		lines << '本项目没有声明 Relay。可在项目 TOML / Admin UI 中配置 relays 与关联 pipeline。'
	}
	for relay in app.details.relays {
		lines << ['', '${relay.id} · ${relay.mode} / ${relay.carrier}', '地址：${relay.endpoint}',
			'节点：${relay.node_id} · 自动启动连接：${relay.autostart}', '关联 pipeline：']
		lines << if relay.pipelines.len == 0 {
			['尚未关联 pipeline。']
		} else {
			relay.pipelines
		}
	}
	lines << ['', '全部 Pipeline']
	lines << app.details.pipelines
	if app.details_error != '' {
		lines = [app.details_error, '', '原始文件保留，可点击“打开配置”修复。']
	}
	body := ui2.text_area('details_body', lines.join('\n'), ui2.rect(0, 214, width, 450), ui2.BoxStyle{ bg: workbench_sidebar, radius: 7 }, ui2.TextStyle{ size: 12, color: workbench_ink, font_family: 'Menlo' })
	elements << ui2.Element{ ...body, readonly: true }
	return elements
}
