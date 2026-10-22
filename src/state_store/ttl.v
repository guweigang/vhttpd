module state_store

import time

// Millisecond-facing APIs share one conversion boundary. Nonpositive values
// retain the existing no-expiry meaning; a positive TTL must not wrap to it.
pub fn ttl_from_milliseconds(ttl_ms i64) !time.Duration {
	if ttl_ms <= 0 { return time.Duration(0) }
	if ttl_ms > i64(9223372036854775807) / i64(time.millisecond) {
		return error('state_store_ttl_out_of_range')
	}
	return time.Duration(ttl_ms * i64(time.millisecond))
}
