module application_logs

import sync
import time

pub const records_per_application = 256
pub const max_applications = 64
pub const max_message_bytes = 4096

// Identity comes from the compiled plan, never from JavaScript or log text.
pub struct Scope {
pub:
	app_id string
	engine_id string
	listener_id string
}

pub struct Record {
pub:
	id u64
	at_unix i64
	at_ms i64
	app_id string
	engine_id string
	listener_id string
	pipeline_id string
	lane_id string
	request_id string
	trace_id string
	level string
	source string
	message string
}

pub struct Snapshot {
pub:
	file string
	storage_error string
	max_file_bytes i64 = max_file_bytes
	backup_files int = backup_files
	version int
	records []Record
	retained int
	dropped u64
	next_cursor u64
	records_per_application int = records_per_application
}

struct Buffer {
mut:
	records []Record
	head int
	dropped u64
	storage_error string
}

@[heap]
pub struct Store {
mut:
	mu sync.Mutex
	sequence u64
	buffers map[string]Buffer
	directory string
	storage_error string
}

const process_logs = &Store{}

pub fn shared() &Store { return unsafe { process_logs } }

pub fn (mut store Store) append(scope Scope, entry Record) {
	store.mu.@lock()
	defer { store.mu.unlock() }
	// Keep unknown/shared-engine output in the environment bucket. Bound both
	// application cardinality and message size, independently of request count.
	key := if scope.app_id in store.buffers || store.buffers.len < max_applications {
		scope.app_id
	} else { '' }
	mut buffer := store.buffers[key] or { store.load_buffer(key) }
	now := u64(time.now().unix_micro())
	if now > store.sequence { store.sequence = now } else { store.sequence++ }
	message := log_message(entry.message)
	record := Record{
		...entry
		id:store.sequence
		at_unix:time.now().unix()
		at_ms:time.now().unix_milli()
		app_id:key
		engine_id:scope.engine_id.clone()
		listener_id:scope.listener_id.clone()
		request_id:log_identity(entry.request_id)
		trace_id:log_identity(entry.trace_id)
		pipeline_id:log_identity(entry.pipeline_id)
		lane_id:log_identity(entry.lane_id)
		message:message
	}
	if buffer.records.len < records_per_application {
		buffer.records << record
	} else {
		buffer.records[buffer.head] = record
		buffer.head = (buffer.head+1)%records_per_application
		buffer.dropped++
	}
	if store.directory != '' {
		buffer.storage_error = ''
		store.persist(key,record) or { buffer.storage_error = err.msg() }
	}
	store.buffers[key] = buffer
}

fn log_identity(value string) string {
	mut end := if value.len > 256 { 256 } else { value.len }
	if value.len > end { for end > 0 && value[end] & 0xc0 == 0x80 { end-- } }
	return value[..end].clone()
}

fn log_message(value string) string {
	if value.len <= max_message_bytes { return value.clone() }
	mut end := max_message_bytes
	for end > 0 && value[end] & 0xc0 == 0x80 { end-- }
	return value[..end].clone()+'… [truncated]'
}

pub fn (mut store Store) snapshot(app_id string, source string, after u64, limit int) Snapshot {
	store.mu.@lock()
	defer { store.mu.unlock() }
	mut records := []Record{}
	mut dropped := u64(0)
	mut retained := 0
	if app_id != '*' && app_id !in store.buffers && store.directory != '' && store.buffers.len < max_applications && store.has_file(app_id) {
		store.buffers[app_id] = store.load_buffer(app_id)
	}
	for key, buffer in store.buffers {
		if app_id != '*' && key != app_id { continue }
		dropped += buffer.dropped
		retained += buffer.records.len
		for record in buffer.records {
			if record.id > after && (source == '' || record.source == source) {
				records << record
			}
		}
	}
	records.sort(a.id < b.id)
	bound := if limit < 1 { 200 } else if limit > 1000 { 1000 } else { limit }
	if records.len > bound { records = records[records.len-bound..].clone() }
	return Snapshot{
		version:1,records:records,retained:retained,dropped:dropped,next_cursor:store.sequence
		file:if app_id != '*' && store.directory != '' {store.log_path(app_id)} else {''}
		storage_error:if store.storage_error != '' {store.storage_error} else {(store.buffers[app_id] or {Buffer{}}).storage_error}
	}
}
