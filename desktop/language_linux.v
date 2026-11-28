module main

import os

fn system_language() string {
	for key in ['LC_ALL', 'LC_MESSAGES', 'LANG'] {
		if value := os.getenv_opt(key) {
			if value != '' { return value }
		}
	}
	return 'en'
}
