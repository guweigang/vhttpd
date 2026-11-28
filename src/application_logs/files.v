module application_logs

import crypto.sha256
import json2 as json
import logging
import os

pub const max_file_bytes = i64(4 * 1024 * 1024)
pub const backup_files = 3

// One environment/process owns this private directory. No application output
// may supply a filename; unusual IDs use a deterministic, path-safe hash.
fn log_filename(app_id string) string {
	if app_id == '' { return 'environment.ndjson' }
	if app_id.len <= 80 && app_id.bytes().all((it >= `a` && it <= `z`) || (it >= `A` && it <= `Z`) || (it >= `0` && it <= `9`) || it in [`_`,`-`]) {
		return 'app-'+app_id+'.ndjson'
	}
	return 'app-'+sha256.hexhash(app_id)+'.ndjson'
}

fn (store &Store) log_path(app_id string) string {
	return os.join_path(store.directory,log_filename(app_id))
}

fn (store &Store) has_file(app_id string) bool {
	path := store.log_path(app_id)
	for i in 0..backup_files+1 {
		candidate := if i == 0 {path} else {path+'.'+i.str()}
		if os.is_file(candidate) && !os.is_link(candidate) {return true}
	}
	return false
}

pub fn (mut store Store) configure_directory(path string) ! {
	store.mu.@lock()
	defer { store.mu.unlock() }
	directory := os.abs_path(path)
	if store.directory != '' {
		if store.directory != directory { return error('application_log_directory_already_bound') }
		return
	}
	if os.is_link(directory) { store.storage_error='application_log_directory_symlink'; return error(store.storage_error) }
	os.mkdir_all(directory,mode:0o700) or { store.storage_error='application_log_directory_unavailable'; return err }
	os.chmod(directory,0o700) or { store.storage_error='application_log_directory_permissions'; return err }
	store.directory = directory
	store.storage_error = ''
}

// Called with Store.mu held, keeping a whole JSON record and its rotation in
// one critical section. The private directory protects files on all backends.
fn (store &Store) persist(app_id string, record Record) ! {
	path := store.log_path(app_id)
	if os.is_link(path) { return error('application_log_file_symlink') }
	line := json.encode(record,escape_unicode:true,time_as_unix:true)
	current_bytes := if os.is_file(path) { os.file_size(path) } else { u64(0) }
	if current_bytes+u64(line.len+1) > u64(max_file_bytes) {
		for i := backup_files; i >= 1; i-- {
			destination := path+'.'+i.str()
			source := if i == 1 {path} else {path+'.'+(i-1).str()}
			if os.is_link(source) || os.is_link(destination) { return error('application_log_rotation_symlink') }
			if os.exists(destination) { os.rm(destination)! }
			if os.exists(source) { os.mv(source,destination)! }
		}
	}
	logging.append_line(path,line)!
	os.chmod(path,0o600)!
}

fn (mut store Store) load_buffer(app_id string) Buffer {
	mut buffer := Buffer{}
	if store.directory == '' { return buffer }
	path := store.log_path(app_id)
	mut records := []Record{}
	for i in 0..backup_files+1 {
		candidate := if i == 0 {path} else {path+'.'+i.str()}
		if !os.is_file(candidate) || os.is_link(candidate) { continue }
		mut file := os.open_file(candidate,'r') or { buffer.storage_error='application_log_read_failed'; continue }
		size := os.file_size(candidate)
		// Tail reads are bounded even when an external writer corrupts/grows a
		// file. In-memory history remains bounded independently of disk history.
		bytes := if size > u64(max_file_bytes) {int(max_file_bytes)} else {int(size)}
		offset := size-u64(bytes)
		raw := file.read_bytes_at(bytes,offset).bytestr()
		file.close()
		for n,line in raw.split_into_lines() {
			if offset > 0 && n == 0 { continue }
			if line.len > 65536 { continue }
			record := json.decode[Record](line) or { continue }
			if record.app_id != app_id || record.source !in ['console','request','relay'] { continue }
			records << Record{
				...record
				message:log_message(record.message)
				request_id:log_identity(record.request_id)
				trace_id:log_identity(record.trace_id)
				engine_id:log_identity(record.engine_id)
				listener_id:log_identity(record.listener_id)
				pipeline_id:log_identity(record.pipeline_id)
				lane_id:log_identity(record.lane_id)
			}
			if record.id > store.sequence { store.sequence = record.id }
		}
		if records.len >= records_per_application { break }
	}
	records.sort(a.id < b.id)
	buffer.dropped = if records.len > records_per_application {u64(records.len-records_per_application)} else {u64(0)}
	buffer.records = if records.len > records_per_application {records[records.len-records_per_application..].clone()} else {records}
	return buffer
}
