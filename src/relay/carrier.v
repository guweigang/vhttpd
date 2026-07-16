module relay

pub struct CarrierSendResult {
pub:
	ok        bool
	trace_id  string
	frame_id  string
	error     string
	queued    bool
}

pub struct CarrierCloseResult {
pub:
	ok         bool
	trace_id   string
	channel_id string
	error      string
}

pub interface Carrier {
	id() string
	connected() bool
mut:
	send(frame WireFrame) CarrierSendResult
	close_channel(channel_id string, trace_id string) CarrierCloseResult
	close()
}

pub struct DisabledCarrier {
pub:
	name string = 'disabled'
}

pub fn (carrier DisabledCarrier) id() string {
	return carrier.name
}

pub fn (carrier DisabledCarrier) connected() bool {
	return false
}

pub fn (mut carrier DisabledCarrier) send(frame WireFrame) CarrierSendResult {
	return CarrierSendResult{
		ok:       false
		trace_id: frame.trace_id
		frame_id: frame.id
		error:    'relay_carrier_disabled:${carrier.name}'
	}
}

pub fn (mut carrier DisabledCarrier) close_channel(channel_id string, trace_id string) CarrierCloseResult {
	return CarrierCloseResult{
		ok:         false
		trace_id:   trace_id
		channel_id: channel_id
		error:      'relay_carrier_disabled:${carrier.name}'
	}
}

pub fn (mut carrier DisabledCarrier) close() {}

pub fn carrier_send_event_fields(result CarrierSendResult) map[string]string {
	return event_fields(if result.ok { 'carrier.send' } else { 'carrier.send_failed' },
		result.trace_id, {
		'frame_id': result.frame_id
		'queued':   result.queued.str()
		'error':    result.error
	})
}

pub fn carrier_close_event_fields(result CarrierCloseResult) map[string]string {
	return event_fields(if result.ok { 'carrier.close_channel' } else { 'carrier.close_channel_failed' },
		result.trace_id, {
		'channel_id': result.channel_id
		'error':      result.error
	})
}
