module host

import app_meta
import json2 as json
import os

fn (mut d DevelopmentState) install_application(mut m Manager, call DevelopmentCall, args DevelopmentArgs) !string {
	if d.application.id != '' || !isnil(call.grant) {
		return error('workspace_session_required')
	}
	if !isnil(m.process) || m.phase in [.running, .starting, .stopping] {
		return error('stop_current_runtime_first')
	}
	if call.tool == 'application_install_apply' {
		if args.id == '' || args.id != d.component_plan_id || call.access != d.component_access {
			return error('invalid_application_install_plan')
		}
		m.install_component(args.id, call.binary)!
		d.component_plan_id = ''
		d.component_access = unsafe { nil }
		return '{"installed":true}'
	}
	if (args.path == '') == (args.template == '') || (args.path != '' && args.component_port != 0) {
		return error('specify_template_or_application_path')
	}
	source := if args.template != '' {
		create_application_source(args.name, args.template, args.component_port)!
	} else {
		path := development_target(call.root, args.path)!
		source_project := application_source_from_file(path)!
		meta := app_meta.read(source_project.workdir)!
		entry := os.path_rel(call.root, source_project.config_path)!.replace('\\', '/')
		if development_target(call.root, entry)! != source_project.config_path
			|| meta.entry != os.file_name(source_project.config_path) {
			return error('app_meta_entry_mismatch')
		}
		source_project
	}
	m.preview_component(source, args.name)!
	d.component_plan_id = m.component_preview.id
	d.component_access = call.access
	preview := m.component_preview
	return json.encode({
		'id': json.Any(preview.id)
		'component': json.Any(args.name)
		'files': json.decode[json.Any](json.encode(preview.files))!
	})
}
