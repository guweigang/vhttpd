module host

import net
import net.http
import os
import time

// Run against a newly built service, not the user's running Desktop environment.
fn test_desktop_installs_two_codexbot_applications_with_private_configuration() ! {
	binary := os.getenv('VHTTPD_COMPONENT_TEST_BIN')
	if binary == '' { return }
	root := os.join_path(os.real_path(os.temp_dir()), 'desktop-codexbot-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	project := create_project(CreateProjectOptions{ name: 'environment', parent_dir: root, template: 'environment' })!
	mut manager := new_manager()
	defer { manager.shutdown() }
	manager.start_timeout = 180000
	manager.stop_timeout = 20000
	manager.start(project, binary)!
	manager.installation_ready()!
	repo := os.real_path(os.join_path(os.dir(@FILE), '..', '..', 'examples', 'codexbot-app-ts'))
	mut ports := []int{}
	for id in ['codexbot_one', 'codexbot_two'] {
		source := root + '/' + id
		os.mkdir(source)!
		for extension in ['.mts', '.mjs', '.ts', '.json'] {
			for file in os.walk_ext(repo, extension) {
				if file.ends_with('bot.local.json') || file.contains('/tests/') { continue }
				target := source + '/' + file[repo.len + 1..]
				os.mkdir_all(os.dir(target))!
				os.cp(file, target)!
			}
		}
		mut socket := net.listen_tcp(.ip, '127.0.0.1:0')!
		port := socket.addr()!.port()!
		socket.close()!
		ports << port
		component := os.read_file(repo + '/component.toml')!.replace('codexbot', id).replace('port = 19883', 'port = ${port}')
		os.write_file(source + '/component.toml', component)!
		config := os.read_file(os.real_path(os.join_path(os.dir(@FILE), '..', '..', 'src', 'testdata', 'codexbot-config.json')))!.replace('"startup": true', '"startup": false').replace('"token": ""', '"token": "${id}-token"')
		os.write_file(source + '/config/bot.example.json', config)!
		// Private source credentials must not be copied into the installation.
		os.write_file(source + '/config/bot.local.json', '{"private_source_secret":"must-not-ship"}')!
		manager.preview_component(project_from_file(source + '/component.toml', source)!, id)!
		manager.install_component(manager.component_preview.id, binary) or {
			eprintln(manager.lines.join("\n"))
			return err
		}
		assert manager.phase == .running
		installed := project.workdir + '/apps/' + id
		assert !os.exists(installed + '/config/bot.local.json')
		os.write_file(installed + '/config/bot.local.json', config)!
		for i, active in ports {
			app_id := ['codexbot_one', 'codexbot_two'][i]
			denied := http.get('http://127.0.0.1:${active}/admin/state')!
			assert denied.status_code == 401
			response := http.fetch(url: 'http://127.0.0.1:${active}/admin/state', header: http.new_header(key: .authorization, value: 'Bearer ${app_id}-token'))!
			assert response.status_code == 200, response.body
			assert response.body.contains(project.workdir + '/apps/' + app_id + '/data/codexbot.sqlite'), response.body
		}
	}
	assert os.exists(project.workdir + '/apps/codexbot_one/config/bot.local.json')
	assert os.exists(project.workdir + '/apps/codexbot_one/data/codexbot.sqlite')
	assert os.exists(project.workdir + '/apps/codexbot_two/data/codexbot.sqlite')
}
