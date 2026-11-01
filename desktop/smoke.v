module main

import host
import net
import net.http
import os
import time

// Uses exactly the same manager as the UI; no mock server or shell launcher.
fn run_smoke(root string) ! {
	mut manager := host.new_manager()
	defer { manager.shutdown() }
	dir := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-smoke-created-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	mut projects := []host.Project{}
	registry := os.join_path(dir, 'projects.json')
	for template in host.project_templates() {
		results := chan CreationResult{cap: 1}
		create_and_register(host.CreateProjectOptions{
			name:       'smoke-${template.id}'
			parent_dir: dir
			template:   template.id
		}, registry, projects, results)
		created := <-results
		if !created.registered { return error(created.error) }
		projects = host.load_projects(registry, [])!
		project := projects.last()
		info := host.inspect_project(project)!
		name := project.name
		binary := os.getenv_opt('VHTTPD_DESKTOP_BINARY') or { host.workbench_binary(os.executable(), root) }
		if template.id == 'vjsx-http' {
			// A broken entry still leaves vhttpd's control listener alive. The
			// desktop must reject readiness and allow retry of this same project.
			entry := os.join_path(project.workdir, 'main.mjs')
			original := os.read_file(entry)!
			os.write_file(entry, 'export default { broken syntax };')!
			manager.start(project, binary)!
			failure_deadline := time.ticks() + 90000
			for manager.snapshot().phase == .starting && time.ticks() < failure_deadline {
				manager.tick()
				time.sleep(60 * time.millisecond)
			}
			if manager.snapshot().phase != .failed { return error('Broken vjsx entry phase=' + manager.snapshot().phase.str() + '\n' + manager.snapshot().logs) }
			cleanup_deadline := time.ticks() + 7000
			for manager.snapshot().pid > 0 && time.ticks() < cleanup_deadline {
				manager.tick()
				time.sleep(60 * time.millisecond)
			}
			if manager.snapshot().pid != 0 || !manager.snapshot().message.contains('执行器初始化失败') {
				return error('Failed executor was not cleaned up with an actionable reason: ' + manager.snapshot().logs)
			}
			os.write_file(entry, original)!
			println('PASS broken vjsx entry: failure detected, child reaped, same project ready for retry')
		}
		manager.start(project, binary)!
		deadline := time.ticks() + 90000
		for manager.snapshot().phase == .starting && time.ticks() < deadline {
			manager.tick()
			time.sleep(60 * time.millisecond)
		}
		mut ready := manager.snapshot()
		if ready.phase != .running {
			return error('${name} failed: ${ready.message}\n${ready.logs}')
		}
		if host.admin_ready(ready.admin_url, 'incorrect-token') {
			return error('Incorrect token accepted')
		}
        if template.id == 'environment' {
            if info.app_url != '' { return error('Empty environment unexpectedly has a business listener') }
            mut ports := []int{}
            for i in 0 .. 2 {
                mut reservation := net.listen_tcp(.ip, '127.0.0.1:0')!
                port := reservation.addr()!.port()!
                reservation.close()!
                ports << port
                source := os.join_path(dir, 'component-${i}')
                os.mkdir(source)!
                os.write_file(source + '/component.toml', '[listeners.demo${i}]\nprotocol="http"\nhost="127.0.0.1"\nport=${port}\n[engines.demo${i}]\nkind="vjsx"\nentry="main.mjs"\nruntime_profile="script"\nthread_count=1\n[adapters.demo${i}]\nkind="http-handler"\nengine="engine:demo${i}"\n[[pipelines]]\nid="demo${i}"\ningress="listener:demo${i}"\negress="adapter:demo${i}"\n')!
                os.write_file(source + '/main.mjs', 'export default c => c.json({application:"demo${i}"},200)')!
                manager.preview_component(host.project_from_file(source + '/component.toml', source)!, 'demo${i}')!
                manager.install_component(manager.snapshot().component_preview.id, binary)!
                for j, active in ports {
                    response := http.get('http://127.0.0.1:${active}/')!
                    if response.status_code != 200 || !response.body.contains('demo${j}') { return error('Independent component request failed') }
                }
            }
            ready = manager.snapshot()
            println('PASS empty environment: Admin-only ready, independently installed two vjsx applications, both responding after shared runtime restart')
        } else {
            response := http.get('${info.app_url}/hello?name=workbench')!
            if response.status_code != 200 || !response.body.contains(name) { return error('Application request failed: ${response.body}') }
        }
		ui := http.get(ready.admin_url)!
		if ui.status_code != 200 || !ui.body.contains('vhttpd Admin') {
			return error('Admin UI did not load: ${ui.status_code}')
		}
		if '--open-browser' in os.args { manager.open_admin()! }
		pid := ready.pid
		manager.stop()
		stop_deadline := time.ticks() + 7000
		for manager.snapshot().pid != 0 && time.ticks() < stop_deadline {
			manager.tick()
			time.sleep(50 * time.millisecond)
		}
		if manager.snapshot().phase != .stopped {
			return error('Stop failed: ${manager.snapshot().logs}')
		}
		mut released := net.listen_tcp(.ip, '127.0.0.1:${info.admin_port}')!
		released.close()!
		println('PASS ${name}: PID ${pid}, created + registered + reloaded, authenticated ready, HTTP response, Admin UI, graceful stop, port released')
	}
}
