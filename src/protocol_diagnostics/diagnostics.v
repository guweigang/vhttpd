module protocol_diagnostics

import time

// Value-only, bounded metadata: never retain a frame, credential or RPC error body.
// The containing provider's lock owns all mutations and snapshot publication.
pub struct Snapshot {
pub mut:
	status              string = 'unchecked'
	stage               string
	code                string
	error_class         string
	checked_at_unix_ms  i64
	decode_errors       i64
	unknown_messages    i64
	handshake_failures  i64
	last_unknown_method string
}

pub fn safe_method(value string) string {
	if value.len == 0 || value.len > 120 || !value.bytes().all(it.is_alnum() || it in [
		`/`,
		`_`,
		`-`,
		`.`,
	]) {
		return '<invalid-method>'
	}
	return value
}

pub fn (mut s Snapshot) checking(stage string) {
	s.status = 'checking'
	s.stage = stage
	s.code = ''
	s.error_class = ''
	s.checked_at_unix_ms = time.now().unix_milli()
}

pub fn (mut s Snapshot) passed(stage string) {
	s.status = 'passed'
	s.stage = stage
	s.code = ''
	s.error_class = ''
	s.checked_at_unix_ms = time.now().unix_milli()
}

pub fn (mut s Snapshot) failed(stage string, code string, error_class string) {
	s.status = 'failed'
	s.stage = stage
	s.code = code
	s.error_class = error_class
	s.checked_at_unix_ms = time.now().unix_milli()
	if stage == 'initialize' { s.handshake_failures++ }
	if code in ['invalid_json', 'invalid_envelope', 'invalid_protobuf', 'invalid_payload',
		'invalid_client_config'] {
		s.decode_errors++
	}
}

pub fn (mut s Snapshot) unknown(method string) {
	s.unknown_messages++
	s.last_unknown_method = safe_method(method)
	s.status = 'warning'
	s.stage = 'dispatch'
	s.code = 'unknown_method'
	s.error_class = 'unrecognized_message'
	s.checked_at_unix_ms = time.now().unix_milli()
}
