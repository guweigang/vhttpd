module ws

import relay

pub fn build_relay_agent_hello_payload(descriptor relay.RelayDescriptor, trace_id string) !string {
	if descriptor.mode != .agent {
		return error('relay_agent_hello_requires_agent_mode:${descriptor.id}')
	}
	frame := relay.registration_hello_frame(relay.registration_request_from_descriptor(descriptor,
		trace_id))!
	return relay.encode_frame(frame)!
}

pub fn relay_agent_hello_event_fields(descriptor relay.RelayDescriptor, trace_id string) map[string]string {
	return relay.event_fields('agent.hello', trace_id, {
		'relay_id': descriptor.id
		'node_id':  descriptor.node_id
		'url':      descriptor.url
	})
}
