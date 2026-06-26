module relay

import runtime_plan

pub enum RelayMode {
	hub
	agent
}

pub struct RelayDescriptor {
pub:
	id                 string
	mode               RelayMode
	carrier            string
	listener           ?runtime_plan.ResourceRef
	auth               ?runtime_plan.ResourceRef
	url                string
	path               string
	node_id            string
	token              string
	max_channels       int
	channel_buffer     int
	reconnect_delay_ms int
	options            runtime_plan.PlanOptions
}

pub fn descriptor_from_plan(plan runtime_plan.RelayPlan) !RelayDescriptor {
	mode := relay_mode_from_string(plan.mode)!
	node_id := relay_node_id(plan)
	descriptor := RelayDescriptor{
		id:                 plan.id
		mode:               mode
		carrier:            relay_carrier_or_default(plan.carrier)
		listener:           plan.ingress
		auth:               plan.auth
		url:                plan.options.strings['url']
		path:               plan.options.strings['path']
		node_id:            node_id
		token:              plan.options.strings['token']
		max_channels:       relay_int_or_default(plan.options, 'max_channels', 1024)
		channel_buffer:     relay_int_or_default(plan.options, 'channel_buffer', 64)
		reconnect_delay_ms: relay_int_or_default(plan.options, 'reconnect_delay_ms', 1000)
		options:            plan.options
	}
	validate_descriptor(descriptor)!
	return descriptor
}

pub fn descriptors_from_plan(plan runtime_plan.RuntimePlan) !map[string]RelayDescriptor {
	mut descriptors := map[string]RelayDescriptor{}
	mut ids := plan.relays.keys()
	ids.sort()
	for id in ids {
		descriptors[id] = descriptor_from_plan(plan.relays[id])!
	}
	return descriptors
}

pub fn validate_descriptor(descriptor RelayDescriptor) ! {
	if descriptor.id.trim_space() == '' {
		return error('relay_descriptor_missing_id')
	}
	if descriptor.carrier != 'websocket' {
		return error('relay_descriptor_unsupported_carrier:${descriptor.carrier}')
	}
	match descriptor.mode {
		.hub {
			if descriptor.listener == none {
				return error('relay_descriptor_hub_missing_listener:${descriptor.id}')
			}
		}
		.agent {
			if descriptor.url.trim_space() == '' {
				return error('relay_descriptor_agent_missing_url:${descriptor.id}')
			}
		}
	}
	if descriptor.node_id.trim_space() == '' {
		return error('relay_descriptor_missing_node_id:${descriptor.id}')
	}
	if descriptor.max_channels <= 0 {
		return error('relay_descriptor_invalid_max_channels:${descriptor.id}')
	}
	if descriptor.channel_buffer <= 0 {
		return error('relay_descriptor_invalid_channel_buffer:${descriptor.id}')
	}
	if descriptor.reconnect_delay_ms < 0 {
		return error('relay_descriptor_invalid_reconnect_delay_ms:${descriptor.id}')
	}
}

fn relay_mode_from_string(value string) !RelayMode {
	normalized := value.trim_space().to_lower()
	return match normalized {
		'', 'hub', 'server' { RelayMode.hub }
		'agent', 'client' { RelayMode.agent }
		else { error('relay_descriptor_unsupported_mode:${value}') }
	}
}

fn relay_carrier_or_default(value string) string {
	normalized := value.trim_space().to_lower()
	if normalized == '' {
		return 'websocket'
	}
	return normalized
}

fn relay_node_id(plan runtime_plan.RelayPlan) string {
	if raw := plan.options.strings['node_id'] {
		if raw.trim_space() != '' {
			return raw.trim_space()
		}
	}
	return plan.id
}

fn relay_int_or_default(options runtime_plan.PlanOptions, key string, default_value int) int {
	if value := options.ints[key] {
		if value > 0 {
			return value
		}
	}
	return default_value
}
