module main

import host
import os
import ui2

struct CreationResult {
	project    host.Project
	registered bool
	error      string
}

fn (mut app Workshop) show_new_project() {
	if app.runtime_busy {
		app.show_runtime = true
		return
	}
	if app.snapshot.pid != 0 || app.snapshot.phase in [.starting, .stopping] { return }
	app.new_project = true
	app.new_name = 'my-vjsx-app'
	app.new_template = 0
	app.new_error = ''
	if app.new_parent == '' { app.new_parent = os.home_dir() }
}

fn (mut app Workshop) submit_new_project() {
	if app.creating { return }
	options := host.CreateProjectOptions{
		name:       app.new_name
		parent_dir: app.new_parent
		template:   host.project_templates()[app.new_template].id
	}
	target := host.project_target(options) or {
		app.new_error = err.msg()
		return
	}
	if os.exists(target) || os.is_link(target) {
		app.new_error = '项目目录已经存在，请更换名称或存放目录。'
		return
	}
	app.new_error = ''
	app.creating = true
	spawn create_and_register(options, app.registry, app.projects.clone(), app.creation_results)
}

fn create_and_register(options host.CreateProjectOptions, registry string, projects []host.Project, results chan CreationResult) {
	project := host.create_project(options) or {
		results <- CreationResult{ error: '创建失败：${err}' }
		return
	}
	mut next := projects.clone()
	next << project
	host.save_projects(registry, next) or {
		results <- CreationResult{ project: project, error: '项目文件已创建，但登记保存失败：${err}。请保留项目并通过“导入项目”重新登记。目录：${project.workdir}' }
		return
	}
	results <- CreationResult{ project: project, registered: true }
}

fn (mut app Workshop) poll_creation() {
	select {
		result := <-app.creation_results {
			app.creating = false
			if !result.registered {
				app.new_error = result.error
				return
			}
			app.projects << result.project
			app.selected = app.projects.len - 1
			app.snapshot = host.Snapshot{}
			app.show_history = false
			app.show_history_diff = false
			app.show_config_diff = false
			app.show_rollback = false
			app.show_details = false
			app.new_project = false
			app.new_error = ''
			app.notice = '项目已创建并登记。'
			if app.new_auto_start { app.launch() } else { app.select_current() }
		}
		else {
		}
	}
}

fn input(id string, value string, placeholder string, x f64, y f64, width f64, enabled bool) ui2.Element {
	el := ui2.text_field_with_change(id, placeholder, value, ui2.rect(x, y, width, 36),
		ui2.BoxStyle{ bg: workbench_paper, radius: 6, border_color: workbench_line, border_left: 1, border_right: 1, border_top: 1, border_bottom: 1 },
		ui2.TextStyle{ size: 13, color: workbench_ink }, 0)
	return ui2.Element{ ...el, enabled: enabled }
}

fn new_project_view(app &Workshop, x f64, width f64) []ui2.Element {
	templates := host.project_templates()
	mut elements := [
		label('new_breadcrumb', '本地项目  /  新建项目', x, 25, width, 12, workbench_muted),
		label('new_title', '新建 vjsx 项目', x, 73, width, 26, workbench_ink),
		label('new_intro', '选择模板和存放目录，创建后即可启动并打开 Admin UI。', x, 110, width, 13, workbench_muted),
		label('template_label', '1  选择项目模板', x, 154, width, 13, workbench_ink),
	]
	for i, template in templates {
		y := 184.0 + f64(i) * 66
		selected := i == app.new_template
		el := painted_button('new_template_${i}', if selected {
			'●  ${template.title}'
		} else {
			'○  ${template.title}'
		}, ui2.rect(x, y, width, 34), ui2.BoxStyle{ bg: if selected {
			workbench_soft_accent
		} else {
			workbench_paper
		}, radius: 6, border_color: if selected { workbench_accent } else { workbench_line }, border_left: 1, border_right: 1, border_top: 1, border_bottom: 1 }, if app.creating {
			u32(0x596575)
		} else if selected {
			workbench_accent
		} else {
			workbench_ink
		}, !app.creating, .left, 12)
		elements << el
		elements << label('template_description_${i}', template.description, x + 4, y + 35, width - 8, 12, workbench_muted)
	}
	elements << label('new_name_label', '2  填写项目名称', x, 326, width, 13, workbench_ink)
	elements << input('new_name', app.new_name, 'my-vjsx-app', x, 353, width, !app.creating)
	elements << label('new_parent_label', '3  选择存放目录', x, 401, width, 13, workbench_ink)
	elements << input('new_parent', app.new_parent, '选择已有文件夹', x, 428, width - 103, !app.creating)
	elements << button('new_choose_parent', '选择目录…', x + width - 92, 428, 92, false, !app.creating)
	target := os.join_path(app.new_parent, app.new_name.trim_space())
	elements << label('new_target', '将创建：${target}', x, 470, width, 11, workbench_muted)
	check := ui2.checkbox('new_auto_start', '创建后立即启动，并打开浏览器 Admin UI', app.new_auto_start, ui2.rect(x, 500, width, 26), ui2.TextStyle{ size: 13, color: workbench_ink })
	elements << ui2.Element{ ...check, enabled: !app.creating }
	elements << button('new_cancel', '取消', x, 662, 78, false, !app.creating)
	elements << button('new_submit', if app.creating {
		'正在创建…'
	} else if app.new_auto_start {
		'创建并启动'
	} else {
		'创建项目'
	}, x + width - 136, 662, 136, true, !app.creating)
	message := if app.new_error != '' {
		app.new_error
	} else {
		if app.creating {
			'正在准备项目文件，请稍候。'
		} else {
			'项目保存在上方目录。创建时自动选择可用端口，已有目录不会覆盖。'
		}
	}
	elements << state_notice('new_message', if app.new_error != '' {
		'创建未完成'
	} else if app.creating {
		'正在创建项目'
	} else {
		'准备好后即可创建'
	}, message, ui2.rect(x, 541, width, 104), if app.new_error != '' { 'danger' } else { 'info' })
	return elements
}
