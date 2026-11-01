module host

import net
import net.http
import os
import time

fn installation_source(root string, id string) !(Project, int) {
	mut socket := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := socket.addr()!.port()!
	socket.close()!
	dir := os.join_path(root, id)
	os.mkdir(dir)!
	os.write_file(dir + '/component.toml', '[listeners.${id}]\nprotocol="http"\nhost="127.0.0.1"\nport=${port}\n[engines.${id}]\nkind="vjsx"\nentry="main.mjs"\nruntime_profile="script"\nthread_count=1\n[adapters.${id}]\nkind="http-handler"\nengine="engine:${id}"\n[[pipelines]]\nid="${id}"\ningress="listener:${id}"\negress="adapter:${id}"\n')!
	os.write_file(dir + '/main.mjs', 'export default c => c.json({app:"${id}"},200)')!
	return project_from_file(dir + '/component.toml', dir)!, port
}

fn test_stopped_environment_installation_and_stale_preview() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'install-stopped-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	project := create_project(CreateProjectOptions{ name: 'environment', parent_dir: root, template: 'environment' })!
	mut manager := new_manager()
	manager.select_project(project)!
	source, _ := installation_source(root, 'alpha')!
	manager.preview_component(source, 'alpha')!
	main := os.read_file(project.config_path)!
	before_token := inspect_project(project)!.config_token
	os.write_file(source.workdir + '/main.mjs', 'export default c => c.json({app:"edited"},200)')!
	mut stale := false
	manager.install_component(manager.component_preview.id, '') or { stale = true }
	assert stale && os.read_file(project.config_path)! == main
	assert !os.exists(project.workdir + '/apps/alpha')
	manager.preview_component(source, 'alpha')!
	mut external := net.listen_tcp(.ip, '127.0.0.1:${inspect_project(project)!.admin_port}')!
	mut blocked := false
	manager.install_component(manager.component_preview.id, '') or { blocked = true }
	assert blocked && os.read_file(project.config_path)! == main
	external.close()!
	manager.install_component(manager.component_preview.id, '')!
	assert manager.phase == .stopped
	assert os.read_file(project.config_path)!.contains('apps/alpha/component.toml')
	assert os.read_file(project.workdir + '/apps/alpha/main.mjs')!.contains('edited')
	assert inspect_project(project)!.config_token == before_token
}

fn test_real_empty_runtime_two_app_install_and_failed_warmup_rollback() ! {
	binary := os.getenv('VHTTPD_COMPONENT_TEST_BIN')
	if binary == '' { return }
	root := os.join_path(os.real_path(os.temp_dir()), 'install-live-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	project := create_project(CreateProjectOptions{ name: 'environment', parent_dir: root, template: 'environment' })!
	initial := os.read_file(project.config_path)!
	os.write_file(project.workdir + '/credentials.json', 'PRIVATE-FIXTURE')!
	mut manager := new_manager()
	defer { manager.shutdown() }
	manager.start_timeout = 20000
	manager.start(project, binary)!
	manager.installation_ready()!
	assert admin_ready(manager.info.admin_url, manager.token)
	assert manager.info.app_url == ''
	mut ports := []int{}
	for id in ['alpha', 'beta'] {
		source, port := installation_source(root, id)!
		ports << port
		manager.preview_component(source, id)!
		manager.install_component(manager.component_preview.id, binary)!
		assert manager.phase == .running
		for i, active in ports {
			assert http.get('http://127.0.0.1:${active}/')!.body.contains(['alpha', 'beta'][i])
		}
		assert os.read_file(project.workdir + '/credentials.json')! == 'PRIVATE-FIXTURE'
		assert os.read_file(project.config_path)!.all_after('[server]') == initial.all_after('[server]')
	}
	before_failure := os.read_file(project.config_path)!
	broken, _ := installation_source(root, 'broken')!
	os.write_file(broken.workdir + '/main.mjs', 'throw new Error("fixture-warmup-failure"); export default c => c.json({ok:true},200);')!
	manager.preview_component(broken, 'broken')!
	mut rolled_back := false
	manager.install_component(manager.component_preview.id, binary) or { rolled_back = err.msg().contains('已恢复') }
	assert rolled_back, manager.message
	assert manager.phase == .running
	assert os.read_file(project.config_path)! == before_failure
	assert !os.exists(project.workdir + '/apps/broken')
	for port in ports {
		assert http.get('http://127.0.0.1:${port}/')!.status_code == 200
	}
}
