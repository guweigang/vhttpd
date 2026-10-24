module admin

fn test_workbench_focus_requires_live_host_and_expires_pending_actions() {
	mut store := WorkbenchFocusStore{}
	store.request('http-123',100) or { assert err.msg().contains('未连接') }
	assert store.poll(100).serial == 0
	store.request('http-123',101) or { panic(err) }
	assert store.poll(102).observation_id == 'http-123'
	store.request('http-123',103) or { panic(err) }
	assert store.poll(104).serial == 2
	store.request('http-123\nsecret',105) or { assert err.msg().contains('无效') }
	assert store.poll(135).serial == 0
	store.request('http-999',141) or { assert err.msg().contains('未连接') }
}
