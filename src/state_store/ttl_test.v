module state_store

import time

fn test_millisecond_ttl_conversion_preserves_bounds_and_no_expiry_semantics() ! {
	for ttl in [i64(-9223372036854775807), i64(-1), i64(0)] {
		assert ttl_from_milliseconds(ttl)! == time.Duration(0)
	}
	for ttl in [i64(1), i64(1000), i64(9223372036854)] {
		assert ttl_from_milliseconds(ttl)!.milliseconds() == ttl
	}
	for ttl in [i64(9223372036855), i64(9223372036854775807)] {
		if _ := ttl_from_milliseconds(ttl) {
			assert false
		} else {
			assert err.msg() == 'state_store_ttl_out_of_range'
		}
	}
}
