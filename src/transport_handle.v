module main

pub struct TransportHandle {
pub:
	protocol  string
	provider  string
	instance  string
	connected bool
	endpoint  string
}

pub fn TransportHandle.for_websocket(provider string, instance string, endpoint string, connected bool) TransportHandle {
	return TransportHandle{
		protocol:  'websocket'
		provider:  provider
		instance:  instance
		connected: connected
		endpoint:  endpoint
	}
}
