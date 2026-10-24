module executor

import time

fn test_bootstrap_budget_preserves_default_and_accepts_bounded_milliseconds() {
	assert inproc_vjsx_bootstrap_budget('')! == 30 * time.second
	assert inproc_vjsx_bootstrap_budget('  ')! == 30 * time.second
	assert inproc_vjsx_bootstrap_budget('120000')! == 120 * time.second
	assert inproc_vjsx_bootstrap_budget(' 1 ')! == time.millisecond
	assert inproc_vjsx_bootstrap_budget('300000')! == 300 * time.second
}

fn test_bootstrap_budget_rejects_unbounded_or_malformed_values() {
	for value in ['0', '-1', '300001', '1.5', '1e3', 'NaN', '120000ms', '+1', '9999999999999999999999999'] {
		mut rejected := false
		inproc_vjsx_bootstrap_budget(value) or {
			rejected = true
			assert err.msg().contains('VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS')
		}
		assert rejected, value
	}
}
