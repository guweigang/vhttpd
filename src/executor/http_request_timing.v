module executor

// Per-request, synchronous dispatch state. Never placed in request headers or JS payloads.
@[heap]
pub struct HttpRequestTiming {
pub mut:
	queue_ns i64
	vjsx_ns i64
	adapter_ns i64
	queue_observed bool
	vjsx_observed bool
	adapter_observed bool
}

pub struct AdminHttpStages {
pub:
	queue_ms f64
	vjsx_ms f64
	adapter_ms f64
	other_ms f64
	queue_observed bool
	vjsx_observed bool
	adapter_observed bool
	available bool
}

pub fn (t &HttpRequestTiming) snapshot(total_ns i64) AdminHttpStages {
	remaining := total_ns - t.queue_ns - t.vjsx_ns - t.adapter_ns
	return AdminHttpStages{queue_ms:f64(t.queue_ns)/1000000.0,vjsx_ms:f64(t.vjsx_ns)/1000000.0,adapter_ms:f64(t.adapter_ns)/1000000.0,other_ms:f64(if remaining > 0 { remaining } else { i64(0) })/1000000.0,queue_observed:t.queue_observed,vjsx_observed:t.vjsx_observed,adapter_observed:t.adapter_observed,available:true}
}
