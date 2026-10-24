module main

import relay

interface RelayIngressDispatchHost {
mut:
	dispatch_and_send_relay_ingress_frame(string, string, relay.WireFrame, i64) []RelayPipelineDispatchOutcome
}
