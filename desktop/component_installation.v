module main

import host
import app_meta
import os
import ui2

fn (mut app Workshop) component_command(commit bool) {
	source := host.application_source_from_file(app.component_file) or {
		app.component_error = err.msg()
		return
	}
	if app.environment_id != '' {
		if !app.server_snapshot.connected {
			app.component_error = '请先在连接与服务器页连接当前服务器。'
			return
		}
		next := app.server_sequence + 1
		select {
			app.server_worker.commands <- host.ServerCommand{
				sequence:      next
				action:        if commit {
					.deploy
				} else {
					.prepare_deploy
				}
				project_id:    app.component_target
				local_project: source
				adopt_engines:app.component_adopt_engines,
                target_installation_id: app.component_installation_id,
                component_id:  app.component_name
				deployment_id: app.server_snapshot.deployment_preview.id
			} {
				app.server_sequence = next
				app.server_busy = true
				app.component_sequence = next
				app.component_action = if commit { 'install' } else { 'preview' }
				if commit { app.component_operation_id = app.server_snapshot.deployment_preview.id }
			}
			else {
				app.component_error = '操作队列繁忙，请稍候。'
			}
		}
	} else {
		if app.snapshot.project != app.component_target {
			app.component_error = '运行环境选择已变化，请重新打开安装页。'
			return
		}
		next := app.sequence + 1
		select {
			app.worker.commands <- host.Command{
				sequence:         next
				action:           if commit {
					.install_component
				} else {
					.preview_component
				}
				component_source: source
				adopt_engines:app.component_adopt_engines,
                target_installation_id:app.component_installation_id,
                component_id:     app.component_name
				version_id:       app.snapshot.component_preview.id
				binary:           app.binary
			} {
				app.sequence = next
				app.component_sequence = next
				app.component_action = if commit { 'install' } else { 'preview' }
				if commit { app.component_operation_id = app.snapshot.component_preview.id }
			}
			else {
				app.component_error = '操作队列繁忙，请稍候。'
			}
		}
	}
}

fn (mut app Workshop) handle_component_event(event string) bool {
	if event in ['component_open','application_new_open'] {
        app.component_adopt_engines=[]string{}
        app.component_installation_id = ''
        app.component_new = event == 'application_new_open'
        app.component_template = 'vjsx-http'
        app.component_port = '0'
		app.show_component_install = true
		app.component_target = if app.environment_id == '' && app.selected >= 0 && app.selected < app.projects.len {
			app.projects[app.selected].config_path
		} else {
			app.remote_id
		}
		app.component_error = ''
		app.component_file = ''
		app.component_name = ''
		app.component_sequence = 0
		app.component_action = ''
		app.component_operation_id = ''
		app.component_preview_before = if app.environment_id == '' {
			app.snapshot.component_preview.id
		} else {
			app.server_snapshot.deployment_preview.id
		}
		app.component_prepared_name = ''
		app.component_prepared_file = ''
		return true
	}
	if !event.starts_with('component_') { return false }
	busy := app.server_busy || app.server_snapshot.busy || app.snapshot.sequence < app.sequence || app.deployment_running()
	if busy { return true }
	match event {
		'component_template_http', 'component_template_api', 'component_template_pipeline',
		'component_template_wechat', 'component_template_codexbot' {
			app.component_template = match event {
				'component_template_http' { 'vjsx-http' }
				'component_template_api' { 'vjsx-api' }
				'component_template_pipeline' { 'pipeline' }
				'component_template_wechat' { 'wechat-cloud-functions' }
				else { 'codexbot' }
			}
			app.reset_component_preview()
		}
        'component_port' {app.component_port=ui2.text(event);app.reset_component_preview()}
        'component_close' { app.show_component_install = false }
		'component_file' {
			app.component_file = ui2.text(event)
			app.reset_component_preview()
		}
		'component_name' {
			app.component_name = ui2.text(event)
			app.reset_component_preview()
		}
		'component_choose' {
			files := ui2.open_file_dialog(
				title: ui_text('选择应用的 app.json 或组件配置（不能包含环境主配置）')
			)
			if files.len > 0 {
				source := host.application_source_from_file(files[0]) or {app.component_error=host.application_identity_hint(err.msg());return true}
                app.component_file=source.config_path
                meta := app_meta.read(source.workdir) or {app_meta.Manifest{}}
                app.component_name = if meta.id != '' {meta.name} else {os.file_name(source.workdir)}
				app.reset_component_preview()
			}
		}
		'component_prepare' {
            if app.component_new {
                if app.component_port == '' || !app.component_port.bytes().all(it.is_digit()) {app.component_error='请填写有效的应用端口。';return true}
                source := host.create_application_source(app.component_name,app.component_template,app.component_port.int()) or {app.component_error=host.application_identity_hint(err.msg());return true}
                app.component_file=source.config_path
            }
			app.component_error = ''
            if app.component_installation_id == '' {
                source := host.application_source_from_file(app.component_file) or {app.component_error=host.application_identity_hint(err.msg());return true}
                app_meta.initialize(source.workdir,app.component_name,os.file_name(source.config_path)) or {app.component_error=host.application_identity_hint(err.msg());return true}
            }
			app.component_preview_before = if app.environment_id == '' {
				app.snapshot.component_preview.id
			} else {
				app.server_snapshot.deployment_preview.id
			}
			app.component_prepared_name = app.component_name
			app.component_prepared_file = app.component_file
			app.component_command(false)
		}
		'component_commit' {
			if !app.component_preview_ready() { return true }
			if app.component_prepared_file == '' || app.component_prepared_name == '' {
				return true
			}
			preview := if app.environment_id == '' {
				app.snapshot.component_preview
			} else {
				app.server_snapshot.deployment_preview
			}
			if preview.id == '' || preview.id == app.component_preview_before { return true }
			if app.component_prepared_name != app.component_name || app.component_prepared_file != app.component_file {
				return true
			}
			if ui_confirm(if app.component_adopt_engines.len > 0 {'迁移旧安装身份'} else if app.component_installation_id != '' {'更新应用'} else {'独立安装应用'}, if app.component_adopt_engines.len > 0 {'将所选旧应用整理为独立组件并增加身份记录；保留私有配置、数据库、存储和其他应用，原代码不删除。运行环境将短暂重启，失败时恢复。是否继续？'} else if app.component_installation_id != '' {'只更新已绑定应用的代码及配置，保留目标环境、共享资源和其他应用。运行中的环境将短暂重启，失败时恢复。是否继续？'} else {'只增加此应用的代码及主配置 include，保留其他应用和共享资源。若运行环境正在运行，将短暂停止并重启其中所有应用；启动失败会恢复。是否继续？'}) {
				app.component_command(true)
			}
		}
		else {}
	}
	return true
}

fn component_installation_view(app &Workshop, width f64) []ui2.Element {
	remote := app.environment_id != ''
	preview := if remote {
		app.server_snapshot.deployment_preview
	} else {
		app.snapshot.component_preview
	}
	busy := app.server_busy || app.server_snapshot.busy || app.snapshot.sequence < app.sequence || app.deployment_running()
	mut rows := [
		label('component_title', if app.component_adopt_engines.len > 0 {'迁移旧安装身份'} else if app.component_installation_id != '' {'更新应用'} else if app.component_new {'新建应用'} else {'安装独立应用'}, 0, 30, width - 130, 24, workbench_colors.ink),
		button('component_close', '返回应用', width - 110, 29, 110, false, !busy),
	]
	mut target_name := os.file_name(os.dir(app.component_target))
	if remote {
		target_name = ui_text('所选运行环境')
		for p in app.server_snapshot.projects {
			if p.id == app.component_target {
				target_name = p.name
				break
			}
		}
		for p in app.remote_profiles {
			if p.id == app.component_target {
				target_name = p.name
				break
			}
		}
	}
	rows << label('component_target_label', ui_text('目标运行环境：') + app.display_environment_name() + ' / ' + target_name, 0, 80, width, 12, workbench_colors.muted)
	rows << state_notice('component_scope', if app.component_installation_id != '' {'核对绑定 → 预览变更 → 更新应用'} else if app.component_new {'选择模板 → 预览改动 → 创建应用'} else {'选择应用 → 预览改动 → 确认安装'}, if app.component_installation_id != '' {'按应用 UUID 和安装 UUID 更新已绑定副本。保留远端监听地址、环境资源、私有配置和未纳入部署的数据；已部署文件发生外部修改时将拒绝覆盖。'} else if app.component_new {'自动生成应用源码和组件配置，并安装到当前运行环境；无需另建进程或管理入口。'} else {'选择包含 component.toml 的应用工程。预览时会为旧工程创建 app.json；安装只新增代码和 include，资源沿用目标运行环境。'}, ui2.rect(0, 110, width, 115), 'info')
	if app.component_new {
        rows << choice_button('component_template_http','HTTP 入门',0,250,(width-12)/2,app.component_template=='vjsx-http',!busy)
        rows << choice_button('component_template_api','JSON API',(width+12)/2,250,(width-12)/2,app.component_template=='vjsx-api',!busy)
        third := (width - 24) / 3
        rows << choice_button('component_template_pipeline','TOML Pipeline',0,288,third,app.component_template=='pipeline',!busy)
        rows << choice_button('component_template_wechat','微信云函数',third+12,288,third,app.component_template=='wechat-cloud-functions',!busy)
        rows << choice_button('component_template_codexbot','Codex Bot',2*(third+12),288,third,app.component_template=='codexbot',!busy)
        rows << label('component_port_label','应用端口（0 自动选择）',0,330,width-120,12,workbench_colors.muted)
        rows << input('component_port',app.component_port,'0',width-100,323,100,!busy)
    } else {
	rows << label('component_file_label', '应用工程中的 app.json 或组件配置', 0, 250, width, 13, workbench_colors.ink)
	rows << input('component_file', app.component_file, '/path/to/application/component.toml', 0, 278, width - 110, !busy && app.component_installation_id == '')
	rows << button('component_choose', '选择文件…', width - 100, 278, 100, false, !busy && app.component_installation_id == '')

    }
	offset := if app.component_new { 38 } else { 0 }
	rows << label('component_name_label', '安装目录名（1–64 位字母、数字、短横线、下划线）', 0, 332 + offset, width, 13, workbench_colors.ink)
	rows << input('component_name', app.component_name, 'my-app', 0, 360 + offset, width, !busy && app.component_installation_id == '')
	rows << button('component_prepare', if busy {
		'正在处理…'
	} else {
		if app.component_installation_id != '' {'预览更新'} else {'预览并检查安装'}
	}, 0, 414 + offset, 180, true, !busy && (app.component_new || app.component_file != '') && app.component_name != '')
	mut y := 472.0 + offset
	title, message, tone := app.component_feedback()
	if message != '' {
		rows << state_notice('component_message', title, message, ui2.rect(0, y, width, 104), tone)
		y += 122
	}
	if app.component_preview_ready() {
		changed := preview.files.filter(it.action != 'unchanged')
		rows << label('component_preview_heading', if app.component_installation_id != '' {'更新预览 · ${changed.len} 个文件变更'} else {'安装预览 · ${changed.len} 个文件变更'}, 0, y, width, 16, workbench_colors.ink)
		y += 36
		for i, file in changed {
			if i >= 40 {
				rows << label('component_more', '其余 ${changed.len - 40} 个文件随应用一起安装。', 0, y, width, 12, workbench_colors.muted)
				y += 30
				break
			}
			rows << label('component_change_${i}', (if file.action == 'add' {
				'新增 · '
            } else if file.action == 'delete' {
                '删除 · '
			} else {
				'更新 · '
			}) + file.path, 0, y, width, 12, workbench_colors.ink)
			y += 28
		}
		rows << button('component_commit', if app.component_installation_id != '' {'更新并应用'} else {'安装并应用'}, 0, y + 16, 160, true, !busy)
		y += 74
	}
	return rows
}

fn (app &Workshop) component_feedback() (string, string, string) {
	if app.component_error != '' { return if app.component_installation_id != '' {'无法继续更新'} else {'无法继续安装'}, app.component_error, 'danger' }
	if app.component_sequence == 0 { return '', '', '' }
	remote := app.environment_id != ''
	result := if remote {
		app.server_snapshot.component_result
	} else {
		app.snapshot.component_result
	}
	if remote && app.component_action == 'install' {
		for status in app.server_snapshot.deployments {
			if status.id != app.component_operation_id { continue }
			return host.application_deployment_title(status), if status.error != '' {
				host.application_deployment_hint(status.error)
			} else if status.phase == 'completed' {
				'本次应用安装已完成，目标运行环境的配置已生效。'
			} else {
				'本次安装正在远端执行，正在等待运行环境确认。'
			}, if status.phase == 'completed' {
				'good'
			} else if status.phase in ['failed', 'rolled_back', 'rollback_failed'] {
				'warning'
			} else {
				'info'
			}
		}
	}
	if remote && !app.server_snapshot.connected {
		return '连接已断开', '重新连接后查看本次操作结果；不会重复提交安装。', 'warning'
	}
	if result.sequence != app.component_sequence || result.target != app.component_target {
		return if app.component_action == 'install' {
			'正在安装应用'
		} else {
			'正在检查安装预览'
		}, '请等待本次操作完成。', 'info'
	}
	if result.error { return '本次操作未完成', result.message, 'danger' }
	if app.component_action == 'preview' {
		if !app.component_preview_ready() {
			return '预览已失效', '请重新预览当前应用的安装改动。', 'warning'
		}
		return '预览检查通过', if app.component_installation_id != '' {'尚未更新。请核对下方文件变更，再点击“更新并应用”。'} else {'尚未安装。请核对下方文件变更，再点击“安装并应用”。'}, 'info'
	}
	if remote {
		return '安装请求已提交', '正在等待本次安装结果。', 'info'
	}
	return if app.component_installation_id != '' {'应用更新完成'} else {'应用安装完成'}, if app.snapshot.phase == .running {
		'应用代码与 include 已写入，运行环境已重新启动。'
	} else {
		'应用代码与 include 已写入，启动运行环境后加载。'
	}, 'good'
}

fn (app &Workshop) component_preview_ready() bool {
	preview := if app.environment_id != '' {
		app.server_snapshot.deployment_preview
	} else {
		app.snapshot.component_preview
	}
	result := if app.environment_id != '' {
		app.server_snapshot.component_result
	} else {
		app.snapshot.component_result
	}
	return app.component_action == 'preview' && app.component_sequence > 0 && result.sequence == app.component_sequence && result.target == app.component_target && !result.error && result.action == 'preview' && result.preview_id == preview.id && preview.id != '' && preview.id != app.component_preview_before && app.component_prepared_name != '' && app.component_prepared_file != '' && app.component_prepared_name == app.component_name && app.component_prepared_file == app.component_file
}

fn (mut app Workshop) reset_component_preview() {
	app.component_error = ''
	app.component_sequence = 0
	app.component_action = ''
	app.component_operation_id = ''
	app.component_prepared_name = ''
	app.component_prepared_file = ''
}
