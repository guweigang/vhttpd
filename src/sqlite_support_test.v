module main

import os
import time

fn test_temp_sqlite_db_path(db_name string) string {
	unique_name := db_name.replace('.sqlite', '') + '_${os.getpid()}_${time.now().unix_micro()}.sqlite'
	return os.join_path(os.temp_dir(), unique_name)
}

fn test_cleanup_sqlite_files(db_path string) {
	os.rm(db_path) or {}
	os.rm(db_path + '-wal') or {}
	os.rm(db_path + '-shm') or {}
}

fn with_temp_sqlite_db_env(env_key string, db_name string, run fn (string)) {
	db_path := test_temp_sqlite_db_path(db_name)
	test_cleanup_sqlite_files(db_path)
	prev := os.getenv(env_key)
	os.setenv(env_key, db_path, true)
	defer {
		if prev == '' {
			os.setenv(env_key, '', true)
		} else {
			os.setenv(env_key, prev, true)
		}
		test_cleanup_sqlite_files(db_path)
	}
	run(db_path)
}
