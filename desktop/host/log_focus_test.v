module host

import os

fn test_focused_logs_use_exact_ids_and_allowlisted_redacted_records() {
	mut m := new_manager()
	m.token = 'fixture-secret'
	m.log('[http.observation] {"observation_id":"http-123","listener":"web","pipeline":"fixture-secret","method":"GET","status":"200","duration_ms":"600","stages_available":"true","queue_observed":"true","queue_ms":"450","vjsx_observed":"true","vjsx_ms":"120","adapter_observed":"true","adapter_ms":"20","other_ms":"10","token":"do-not-show","url":"?secret=hidden"}')
	m.log('[http.observation] {"observation_id":"http-1234","status":"500"}')
	m.log('unrelated http-123 token=do-not-show')
	m.log_filter = 'http-123'
	assert m.snapshot().logs.contains('600')
	assert m.snapshot().logs.contains('vjsx 执行：120 ms')
	assert m.snapshot().logs.contains('排队：450 ms')
	assert m.snapshot().logs.contains('[REDACTED]')
	assert !m.snapshot().logs.contains('do-not-show')
	assert !m.snapshot().logs.contains('fixture-secret')
	assert !m.snapshot().logs.contains('http-1234')
	assert !m.snapshot().logs.contains('hidden')
	m.clear_logs()
	assert m.snapshot().logs.contains('未找到')
	m.log_filter = ''
	assert m.snapshot().logs == ''
	for i in 0 .. 1005 { m.log('[http.observation] {"observation_id":"http-${i}"}') }
	assert m.request_logs.len == 1000
	m.log_filter = 'http-0'
	assert m.snapshot().logs.contains('未找到')
	m.reset_log_focus()
	assert m.snapshot().log_filter == ''
	assert m.request_logs.len == 0
}

fn test_host_poll_sends_a_real_authenticated_request() {
	url := os.getenv('VHTTPD_LOG_FOCUS_TEST_URL')
	if url == '' { return }
	mut m := new_manager()
	m.token = 'fixture-secret'
	m.info = ProjectInfo{admin_url: url}
	m.poll_log_focus()
	assert m.snapshot().log_filter == 'http-987654'
	assert m.snapshot().log_focus_serial == 1
}
