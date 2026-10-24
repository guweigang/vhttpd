module executor

import os
import strconv
import time

// Compiler/module initialization is cold-start work, not a user hook. Keep its
// budget independent of the 10s hook limit, but never allow an unbounded wait.
fn inproc_vjsx_bootstrap_budget(raw string) !time.Duration {
	value := raw.trim_space()
	if value == '' { return inproc_vjsx_lane_bootstrap_timeout }
	if !value.bytes().all(it >= `0` && it <= `9`) {
		return error('invalid VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS: expected 1..300000')
	}
	ms := strconv.atoi(value) or {
		return error('invalid VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS: expected 1..300000')
	}
	if ms < 1 || ms > 300000 {
		return error('invalid VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS: expected 1..300000')
	}
	return time.Duration(ms) * time.millisecond
}

fn inproc_vjsx_configured_bootstrap_budget() !time.Duration {
	return inproc_vjsx_bootstrap_budget(os.getenv('VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS'))
}
