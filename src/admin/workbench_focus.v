module admin

import sync

pub struct WorkbenchFocus {
pub:
	serial u64
	observation_id string
	at_unix i64
}

@[heap]
pub struct WorkbenchFocusStore {
mut:
	mu sync.Mutex
	seen_at i64
	focus WorkbenchFocus
}

pub fn (mut s WorkbenchFocusStore) poll(now i64) WorkbenchFocus {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.seen_at = now
	if s.focus.at_unix < now - 30 { return WorkbenchFocus{} }
	return s.focus
}

pub fn (mut s WorkbenchFocusStore) request(id string, now i64) ! {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if s.seen_at == 0 || now < s.seen_at || now - s.seen_at > 5 { return error('工作台未连接，请从工作台打开此项目。') }
	if !id.starts_with('http-') || id.len < 6 || id.len > 40 || !id[5..].bytes().all(it.is_digit()) { return error('无效的请求定位编号。') }
	s.focus = WorkbenchFocus{serial:s.focus.serial + 1,observation_id:id,at_unix:now}
}
