module windows_files

#flag windows -ladvapi32
#include "@VMODROOT/src/windows_files/native.h"

fn C.vh_open(&char, int, ...int) int
fn C.vh_close(int) int
fn C.vh_write(int, voidptr, u64) i64
fn C.vh_dev(int) u64
fn C.vh_ino(int) u64
fn C.vh_matches(&char, u64, u64) int
fn C.vh_remove_owned(int, &char, u64, u64)
fn C.vh_flock(int, int) int
fn C.vh_fsync(int) int
fn C.vh_rename(&char, &char) int
fn C.vh_lseek(int, i64, int) i64
fn C.vh_ftruncate(int, u64) int

fn C.vh_open_dir(&char) int
fn C.vh_matches_dir(&char, u64, u64) int
