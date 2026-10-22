module upload_store

import os
import time

fn C.fcntl(int, int, ...voidptr) int

fn upload_store_root() string {
	path := os.join_path(os.temp_dir(), 'vhttpd-upload-owner-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}

fn test_upload_is_unpublished_until_write_and_close_complete() {
	root := upload_store_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'upload.bin')
	entered := chan int{cap: 1}
	release := chan bool{cap: 1}
	done := chan string{cap: 1}
	spawn fn [path, entered, release, done] () {
		save_with(path, 'complete data', fn [entered, release] (fd int, data string) ! {
			write_all(fd, data[..4])!
			entered <- fd
			_ := <-release
			write_all(fd, data[4..])!
		}) or {
			done <- err.msg()
			return
		}
		done <- 'ok'
	}()
	fd := <-entered
	assert C.fcntl(fd, C.F_GETFD) & C.FD_CLOEXEC != 0
	assert !os.exists(path)
	assert (os.ls(root) or { panic(err) }).len == 1
	release <- true
	assert <-done == 'ok'
	assert C.fcntl(fd, C.F_GETFD) == -1
	assert os.read_file(path) or { panic(err) } == 'complete data'
	assert os.ls(root) or { panic(err) } == ['upload.bin']
}

fn test_failed_upload_write_closes_fd_and_removes_partial_file() {
	root := upload_store_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'upload.bin')
	mut failed := false
	save_with(path, 'partial data', fn (fd int, data string) ! {
		assert C.fcntl(fd, C.F_GETFD) & C.FD_CLOEXEC != 0
		write_all(fd, data[..3])!
		return error_with_code('injected_write_failure', fd)
	}) or {
		failed = true
		assert err.msg() == 'injected_write_failure'
		assert C.fcntl(err.code(), C.F_GETFD) == -1
	}
	assert failed
	assert !os.exists(path)
	assert (os.ls(root) or { panic(err) }).len == 0
	save(path, 'retry') or { panic(err) }
	assert os.read_file(path) or { panic(err) } == 'retry'
}

fn test_upload_preserves_existing_files_directories_and_symlinks() {
	root := upload_store_root()
	defer { os.rmdir_all(root) or {} }
	for kind in ['file', 'directory', 'symlink', 'dangling'] {
		path := os.join_path(root, kind)
		match kind {
			'file' { os.write_file(path, 'original') or { panic(err) } }
			'directory' { os.mkdir(path) or { panic(err) } }
			'symlink' { os.symlink(os.join_path(root, 'file'), path) or { panic(err) } }
			else { os.symlink(os.join_path(root, 'missing'), path) or { panic(err) } }
		}
		mut failed := false
		save(path, 'replacement') or { failed = true }
		assert failed
		assert (os.ls(root) or { panic(err) }).all(!it.starts_with('.upload-'))
	}
	assert os.read_file(os.join_path(root, 'file')) or { panic(err) } == 'original'
	assert (os.ls(os.join_path(root, 'directory')) or { panic(err) }).len == 0
	assert os.is_link(os.join_path(root, 'symlink'))
	assert os.is_link(os.join_path(root, 'dangling'))
	assert !os.exists(os.join_path(root, 'missing'))
}

fn test_upload_cannot_replace_target_created_while_write_is_in_flight() {
	root := upload_store_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'upload.bin')
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	done := chan bool{cap: 1}
	spawn fn [path, entered, release, done] () {
		save_with(path, 'candidate', fn [entered, release] (fd int, data string) ! {
			write_all(fd, data)!
			entered <- true
			_ := <-release
		}) or {
			done <- true
			return
		}
		done <- false
	}()
	_ := <-entered
	os.write_file(path, 'other owner') or { panic(err) }
	release <- true
	assert <-done
	assert os.read_file(path) or { panic(err) } == 'other owner'
	assert os.ls(root) or { panic(err) } == ['upload.bin']
}

fn upload_compete(path string, value string, done chan string) {
	save(path, value) or {
		done <- ''
		return
	}
	done <- value
}

fn test_concurrent_uploads_to_same_name_have_one_complete_winner() {
	root := upload_store_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'upload.bin')
	done := chan string{cap: 12}
	for i in 0 .. 12 { spawn upload_compete(path, '${i}'.repeat(20000), done) }
	mut winners := []string{}
	for _ in 0 .. 12 {
		result := <-done
		if result != '' { winners << result }
	}
	assert winners.len == 1
	assert os.read_file(path) or { panic(err) } == winners[0]
	assert os.ls(root) or { panic(err) } == ['upload.bin']
}
