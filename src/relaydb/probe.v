module relaydb

import dbx
import json2 as json

// A probe can only evaluate this constant expression, never user SQL or data.
pub const probe_sql = 'SELECT 1 AS relay_probe'

pub struct ProbeResult {
pub:
	ok bool
	stage string
	error string
}

pub fn probe_response(raw string) ProbeResult {
	response := json.decode[dbx.Response](raw) or {
		return ProbeResult{stage: 'response', error: 'invalid_database_response'}
	}
	if !response.ok { return ProbeResult{stage: 'database', error: 'database_operation_failed'} }
	if response.driver != 'mysql' || response.rows.len != 1 || response.rows[0]['relay_probe'] != '1' {
		return ProbeResult{stage: 'response', error: 'unexpected_probe_result'}
	}
	return ProbeResult{ok: true, stage: 'query'}
}
