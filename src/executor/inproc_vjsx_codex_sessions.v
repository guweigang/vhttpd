module executor

import os

struct CodexSessionLocator {}

fn CodexSessionLocator.sessions_root() string {
	override_root := os.getenv('VHTTPD_CODEX_SESSIONS_ROOT').trim_space()
	if override_root != '' {
		return override_root
	}
	codex_home := os.getenv('CODEX_HOME').trim_space()
	if codex_home != '' {
		return os.join_path(codex_home, 'sessions')
	}
	home := os.home_dir()
	if home.trim_space() == '' {
		return ''
	}
	return os.join_path(home, '.codex', 'sessions')
}

fn CodexSessionLocator.find_in_dir(dir string, thread_id string) string {
	if dir.trim_space() == '' || thread_id.trim_space() == '' || !os.exists(dir) {
		return ''
	}
	items := os.ls(dir) or { return '' }
	mut names := items.clone()
	names.sort(a > b)
	for name in names {
		path := os.join_path(dir, name)
		if os.is_dir(path) {
			found := CodexSessionLocator.find_in_dir(path, thread_id)
			if found != '' {
				return found
			}
			continue
		}
		if !name.ends_with('.jsonl') {
			continue
		}
		if name.contains(thread_id) {
			return path
		}
	}
	return ''
}

fn CodexSessionLocator.find(thread_id string) string {
	root := CodexSessionLocator.sessions_root()
	if root == '' {
		return ''
	}
	return CodexSessionLocator.find_in_dir(root, thread_id)
}
