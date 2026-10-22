module main

import crypto.sha256
import json2 as json
import net.http
import os
import time

fn upload_owner_root() string {
	path := os.join_path(os.temp_dir(), 'vhttpd-upload-route-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}

fn upload_owner_request(mut app App, root string, method http.Method, body string) Context {
	mut ctx := Context{ req: http.Request{ method: method, url: '/upload', data: body } }
	ctx.req.header.set_custom('x-vhttpd-filename', '../../photo.bin') or { panic(err) }
	handle_upload_route(mut app, mut ctx, RuntimeRouteRule{ upload_dir: root }, method.str(),
		'/upload', 'upload-request', 'upload-trace', time.now().unix_milli(), {}, '', '127.0.0.1')
	return ctx
}

fn test_upload_route_publishes_complete_binary_before_completion_event() {
	root := upload_owner_root()
	defer { os.rmdir_all(root) or {} }
	events := os.join_path(root, 'events.ndjson')
	mut app := App{ control_plane: ControlPlaneRuntime{ event_log: events } }
	data := 'binary\x00payload\xff'
	ctx := upload_owner_request(mut app, os.join_path(root, 'uploads'), .post, data)
	assert ctx.res.status_code == 201
	response := json.decode[UploadResponse](ctx.res.body) or { panic(err) }
	assert response.ok
	assert response.filename == 'photo.bin'
	assert response.size == data.len
	assert response.sha256 == sha256.sum(data.bytes()).hex().to_lower()
	assert os.read_file(response.path) or { panic(err) } == data
	assert os.ls(os.join_path(root, 'uploads')) or { panic(err) } == [os.file_name(response.path)]
	assert (ctx.res.header.get_custom('x-vhttpd-upload-id') or { panic('missing upload id header') }) == response.upload_id
	log := os.read_file(events) or { panic(err) }
	assert log.contains('upload.completed')
	assert log.contains(response.path)
}

fn test_rejected_uploads_allocate_no_storage_and_emit_no_completion() {
	root := upload_owner_root()
	defer { os.rmdir_all(root) or {} }
	events := os.join_path(root, 'events.ndjson')
	mut app := App{ control_plane: ControlPlaneRuntime{ event_log: events } }
	for method in [http.Method.get, .post] {
		ctx := upload_owner_request(mut app, os.join_path(root, 'uploads'), method, '')
		assert ctx.res.status_code == if method == .get { 405 } else { 400 }
		assert !os.exists(os.join_path(root, 'uploads'))
	}
	assert !(os.read_file(events) or { panic(err) }).contains('upload.completed')
}

fn testsuite_begin() {
	if os.args.len == 3 && os.args[1] == '--upload-file-limit-child' {
		upload_owner_limited_process(os.args[2])
		exit(0)
	}
}

fn upload_owner_limited_process(root string) {
	data := 'x'.repeat(16384)
	before := os.join_path(root, 'before.partial')
	mut before_failed := false
	os.write_file(before, data) or { before_failed = true }
	assert before_failed
	assert os.file_size(before) == 4096
	// Exercise the real HTTP entry under the same kernel write limit, not only
	// an injected writer. A 500 response must leave neither an upload nor an event.
	events := os.join_path(root, 'events.ndjson')
	mut app := App{ control_plane: ControlPlaneRuntime{ event_log: events } }
	uploads := os.join_path(root, 'uploads')
	ctx := upload_owner_request(mut app, uploads, .post, data)
	assert ctx.res.status_code == 500
	assert ctx.res.body == 'upload write failed'
	assert (os.ls(uploads) or { panic(err) }).len == 0
	log := os.read_file(events) or { panic(err) }
	assert !log.contains('upload.completed')
	assert log.contains('http.request')
	println('before_bytes=4096 after_upload_files=0 status=500 no_completion=true')
}

fn test_upload_route_real_kernel_write_failure_reclaims_storage() {
	root := upload_owner_root()
	defer { os.rmdir_all(root) or {} }
	mut child := os.new_process('python3')
	child.set_args(['-c',
		'import os, resource, signal, sys
resource.setrlimit(resource.RLIMIT_FSIZE, (4096, 4096))
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
os.execl(sys.argv[1], sys.argv[1], "--upload-file-limit-child", sys.argv[2])', os.executable(),
		root])
	child.set_redirect_stdio()
	child.run()
	defer {
		child.signal_kill()
		child.wait()
		child.close()
	}
	deadline := time.now().add(10 * time.second)
	for child.is_alive() {
		assert time.now() < deadline
		time.sleep(5 * time.millisecond)
	}
	child.wait()
	output := child.stdout_slurp() + child.stderr_slurp()
	assert child.code == 0, output
	assert output.contains('before_bytes=4096 after_upload_files=0 status=500 no_completion=true')
	assert os.file_size(os.join_path(root, 'before.partial')) == 4096
	assert (os.ls(os.join_path(root, 'uploads')) or { panic(err) }).len == 0
}
