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
		label('details_breadcrumb', ui_text('运行环境  /  ${project.name}'), 0, 25, width, 12, workbench_colors.muted),
		label('details_title', ui_text('配置组成'), 0, 73, width, 25, workbench_colors.ink),
		label('details_intro', ui_text('以下来自磁盘配置；连接、重连与通道状态请查看 Admin UI → Relay。'), 0, 111, width, 12, workbench_colors.muted),
		button('details_close', ui_text('返回工作台'), 0, 157, 100, false, true),
		button('details_refresh', ui_text('重新读取'), 112, 157, 90, false, true),
		button('edit_config', ui_text('打开配置'), 214, 157, 90, false, true),
		button('edit_source', ui_text('打开源码'), 316, 157, 90, false, app.details.entry != ''),
		button('admin', 'Admin UI ↗', 418, 157, 115, true, app.snapshot.phase == .running),
	]
	mut lines := [ui_text('运行环境：${project.name}'), ui_text('配置文件：${project.config_path}'),
		ui_text('工作目录：${project.workdir}'), '', ui_text('监听器')]
	lines << app.details.listeners
	lines << ['', ui_text('源码入口')]
	lines << if app.details.sources.len == 0 {
		[ui_text('未声明源码入口。')]
	} else {
		app.details.sources
	}
	lines << ['', ui_text('Relay 配置（运行环境）'),
		ui_text('agent 主动连接 hub；local / remote 表示部署位置，不是运行角色。')]
	if app.details.relays.len == 0 {
		lines << ui_text('此运行环境没有声明 Relay。可在项目 TOML / Admin UI 中配置 relays 与关联 pipeline。')
	}
	for relay in app.details.relays {
		lines << ['', '${relay.id} · ${relay.mode} / ${relay.carrier}', ui_text('地址：${relay.endpoint}'),
			ui_text('节点：${relay.node_id} · 自动启动连接：${relay.autostart}'), ui_text('关联 pipeline：')]
		lines << if relay.pipelines.len == 0 {
			[ui_text('尚未关联 pipeline。')]
		} else {
			relay.pipelines
		}
	}
	lines << ['', ui_text('全部 Pipeline')]
	lines << app.details.pipelines
	if app.details_error != '' {
		lines = [app.details_error, '', ui_text('原始文件保留，可点击“打开配置”修复。')]
	}
	body := ui2.text_area('details_body', lines.join('\n'), ui2.rect(0, 214, width, 450), ui2.BoxStyle{ bg: workbench_colors.sidebar, radius: 7 }, ui2.TextStyle{ size: 12, color: workbench_colors.ink, font_family: workbench_detail_font() })
	elements << ui2.Element{ ...body, readonly: true }
	return elements
}
