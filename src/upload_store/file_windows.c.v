module upload_store

import os
import rand
import windows_files

#include "@VMODROOT/src/windows_files/native.h"

pub fn save(path string, data string) ! {
	save_with(path, data, write_all)!
}

fn save_with(path string, data string, writer fn (int, string) !) ! {
	temporary := os.join_path(os.dir(path), '.upload-${rand.uuid_v4()}.tmp')
	fd := C.vh_open(temporary.str, C.VH_O_WRONLY | C.VH_O_CREAT | C.VH_O_EXCL, 0o666)
	if fd < 0 { return error('upload_create_failed') }
	dev := C.vh_dev(fd)
	ino := C.vh_ino(fd)
	defer {
		C.vh_remove_owned(fd, temporary.str, dev, ino)
		C.vh_close(fd)
	}
	writer(fd, data)!
	if C.vh_fsync(fd) != 0 { return error('upload_sync_failed') }
	if C.vh_matches(temporary.str, dev, ino) == 0 {
		return error('upload_temporary_ownership_changed')
	}
	if C.vh_publish_new(temporary.str, path.str) != 0 { return error('upload_publish_failed') }
}

fn write_all(fd int, data string) ! {
	mut offset := 0
	for offset < data.len {
		n := unsafe { C.vh_write(fd, data.str + offset, data.len - offset) }
		if n <= 0 { return error('upload_short_write') }
		offset += int(n)
	}
}
