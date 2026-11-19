module host

import app_bundle
import app_meta
import json2 as json
import os

// Desktop's local index. Portable app.json and the target installation record
// are authoritative identities; paths are locations, never identities.
pub struct ApplicationBinding {
pub:
	app_id          string
	installation_id string
	source          Project
	server_id       string
	environment_id  string
	config_path     string
	component       string
	engines         []string
	operation_id    string
	fingerprint     string
	version         string
	phase           string
}

pub fn load_application_bindings() ![]ApplicationBinding {
	path := os.join_path(workbench_data_dir(), 'application-bindings.json')
	if !os.exists(path) { return []ApplicationBinding{} }
	if os.is_link(path) || os.file_size(path) > 4 * 1024 * 1024 {
		return error('application_binding_invalid')
	}
	items := json.decode[[]ApplicationBinding](os.read_file(path)!)!
	if items.len > 2048 { return error('application_binding_limit') }
	for item in items {
		if !app_meta.valid_id(item.app_id) || !app_meta.valid_id(item.installation_id) || !app_bundle.valid_component_id(item.component) || item.config_path == '' || item.source.config_path == '' || item.phase !in [
			'pending',
			'installed',
		] {
			return error('application_binding_invalid')
		}
	}
	return items
}

fn write_application_bindings(items []ApplicationBinding) ! {
	if items.len > 2048 { return error('application_binding_limit') }
	path := os.join_path(workbench_data_dir(), 'application-bindings.json')
	if os.is_link(path) { return error('application_binding_invalid') }
	temp := path + '.' + new_remote_id()!
	defer { os.rm(temp) or {} }
	write_project_contents(create_project_file(temp)!, json.encode(items))!
	os.mv(temp, path)!
}

fn record_application_binding(binding ApplicationBinding) ! {
	os.mkdir_all(workbench_data_dir(), mode: 0o700)!
	guard_dir := os.join_path(workbench_data_dir(), '.application-bindings-lock')
	os.mkdir(guard_dir, mode: 0o700) or { return error('application_binding_busy') }
	defer { os.rmdir(guard_dir) or {} }
	mut items := load_application_bindings()!
	items = items.filter(!(it.server_id == binding.server_id && it.config_path == binding.config_path && it.installation_id == binding.installation_id && it.phase == binding.phase && (binding.phase == 'installed' || it.operation_id == binding.operation_id)))
	items << binding
	write_application_bindings(items)!
}

fn complete_application_binding(operation string, succeeded bool) ! {
	os.mkdir_all(workbench_data_dir(), mode: 0o700)!
	guard_dir := os.join_path(workbench_data_dir(), '.application-bindings-lock')
	os.mkdir(guard_dir, mode: 0o700) or { return error('application_binding_busy') }
	defer { os.rmdir(guard_dir) or {} }
	mut items := load_application_bindings()!
	pending := items.filter(it.operation_id == operation && it.phase == 'pending')
	if pending.len == 0 { return }
	if pending.len != 1 { return error('application_binding_invalid') }
	b := pending[0]
	items = items.filter(it.operation_id != operation || it.phase != 'pending')
	if succeeded {
		items = items.filter(!(it.server_id == b.server_id && it.config_path == b.config_path && it.installation_id == b.installation_id && it.phase == 'installed'))
		items << ApplicationBinding{ ...b, phase: 'installed' }
	}
	write_application_bindings(items)!
}

pub fn binding_for_application(server_id string, config_path string, application RuntimeApplication) !ApplicationBinding {
 if application.identity_error != '' || application.identity.app_id == '' || application.identity.installation_id == '' {return ApplicationBinding{}}
	items := load_application_bindings()!
	// Resolve explicitly below rather than ever falling back to display names.
	mut selected := []ApplicationBinding{}
	for b in items {
		if b.phase != 'installed' || b.server_id != server_id || b.config_path != config_path {
			continue
		}
		if application.identity.app_id != '' && (application.identity.app_id != b.app_id || application.identity.installation_id != b.installation_id) {
			continue
		}
		for engine in application.engines {
			if engine.id in b.engines {
				selected << b
				break
			}
		}
	}
	if selected.len > 1 { return error('application_binding_ambiguous') }
	if selected.len == 0 { return ApplicationBinding{} }
	return selected[0]
}

pub fn validate_binding_source(binding ApplicationBinding) !Project {
	meta := app_meta.read(binding.source.workdir)!
	if meta.id != binding.app_id || os.join_path(binding.source.workdir, meta.entry) != binding.source.config_path {
		return error('application_binding_mismatch')
	}
	return binding.source
}

// Explicit association for an already installed application / another machine.
// Verify UUID before changing the source location; never infer by name.
pub fn associate_application_source(server_id string, environment_id string, config_path string, application RuntimeApplication, source Project) ! {
	identity := application.identity
	if application.identity_error != '' || identity.installation_id == '' || identity.app_id == '' {
		return error('application_binding_missing')
	}
	meta := app_meta.read(source.workdir)!
	if meta.id != identity.app_id || meta.entry != identity.entry || source.config_path != os.join_path(source.workdir, meta.entry) {
		return error('application_binding_mismatch')
	}
	record_application_binding(ApplicationBinding{ app_id: identity.app_id, installation_id: identity.installation_id, source: source, server_id: server_id, environment_id: environment_id, config_path: config_path, component: identity.component, engines: application.engines.map(it.id), operation_id: identity.deployment_id, fingerprint: identity.fingerprint, version: identity.version, phase: 'installed' })!
}

pub fn application_identity_hint(reason string) string {
	return match reason {
		'application_binding_missing' {
			'此应用没有可用的安装身份，请先升级运行包并完成应用关联。'
		}
		'application_binding_mismatch', 'application_identity_changed' {
			'应用身份或目标安装身份不一致，已拒绝操作。请核对 app.json 和目标应用。'
		}
		'application_binding_ambiguous' {
			'应用对应关系不唯一，请明确选择安装副本和执行引擎。'
		}
		'application_source_modified' {
			'目标应用的已部署文件发生了外部修改，已拒绝覆盖。请先核对差异。'
		}
		'application_unowned_file_conflict' {
			'新代码与目标中的未管理文件冲突，已拒绝覆盖以保留数据。'
		}
		'application_binding_protocol_unsupported' {
			'远端运行包尚不支持应用身份校验，请先升级运行环境。'
		}
		'app_meta_missing_or_unsafe', 'app_meta_required' {
			'缺少安全可读的 app.json，请在应用源码根目录初始化应用身份。'
		}
		'app_meta_schema_unsupported' { 'app.json 的结构版本不受支持。' }
		'app_meta_invalid_id' {
			'app.json 中的 id 必须是固定的 UUID，不能使用应用名称。'
		}
		'app_meta_invalid_version' {
			'app.json 中的 version 必须是语义化版本，例如 1.0.0。'
		}
		'app_meta_entry_mismatch', 'app_meta_invalid_path' {
			'app.json 的 entry 必须指向当前应用内的组件配置，资源路径不得越界。'
		}
		'app_meta_invalid_json', 'app_meta_invalid_type', 'app_meta_invalid_name',
		'app_meta_invalid_text', 'app_meta_invalid_url', 'app_meta_field_limit',
		'app_meta_too_large', 'app_meta_icon_missing' {
			'app.json 的字段、类型或资源引用无效，请检查应用元数据。'
		}
		else {
			if reason.starts_with('app_meta_unknown_field:') || reason.starts_with('app_meta_missing_field:') {
				'app.json 包含未知字段或缺少必要字段，请按应用元数据结构填写。'
			} else {
				reason
			}
		}
	}
}
